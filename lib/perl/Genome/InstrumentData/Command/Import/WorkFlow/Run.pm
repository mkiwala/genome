package Genome::InstrumentData::Command::Import::WorkFlow::Run;

use strict;
use warnings;

use Genome;

require File::Temp;
require List::MoreUtils;
use Workflow::Simple;

class Genome::InstrumentData::Command::Import::WorkFlow::Run {
    is => 'Command::V2',
    has_input => {
        work_flow_inputs => { is => 'Genome::InstrumentData::Command::Import::WorkFlow::Inputs', },
    },
    has_output => {
        instrument_data => { is => 'Genome::InstrumentData', is_many => 1, },
    },
    has_optional_constant_calculated => {
        helpers => { calculate => q( Genome::InstrumentData::Command::Import::WorkFlow::Helpers->get; ), },
    },
    has_optional_transient => {
        _workflow => {},
        _verify_not_imported_op => {},
        _working_directory => { is => 'Text', },
    },
};

sub shortcut {
    my $self = shift;
    my @instrument_data = $self->work_flow_inputs->instrument_data_for_original_data_path;
    return if not @instrument_data;
    $self->instrument_data(\@instrument_data);
    return 1;
}

sub execute {
    my $self = shift;
    $self->status_message('Import instrument data...');

    my $working_directory = $self->_resolve_working_directory;
    return if not $working_directory;

    my $space_available = $self->_verify_adequate_disk_space_is_available_for_source_files;
    return if not $space_available;

    my $workflow = $self->_build_workflow;
    return if not $workflow;

    my $inputs = $self->work_flow_inputs->as_hashref;
    return if not $inputs;
    $inputs->{working_directory} = $self->_working_directory;

    my $success = Workflow::Simple::run_workflow($workflow, %$inputs);
    die 'Run wf failed!' if not $success;

    $self->instrument_data($success->{instrument_data});

    $self->status_message('Import instrument data...done');
    return 1;
}

sub _resolve_working_directory {
    my $self = shift;

    my $tmp_dir = File::Temp::tempdir(CLEANUP => 1);
    if ( not $tmp_dir ) {
        $self->error_message('Failed to create tmp dir!');
        return;
    }

    return $self->_working_directory($tmp_dir);
}

sub _verify_adequate_disk_space_is_available_for_source_files {
    my $self = shift;
    my $helpers = Genome::InstrumentData::Command::Import::WorkFlow::Helpers->get;
    my $space_available = $self->work_flow_inputs->source_files->verify_adequate_disk_space_is_available_for_processing($self->_working_directory);
    return $space_available;
}

sub _build_workflow {
    my $self = shift;

    my $workflow = Workflow::Model->create(
        name => 'Import Instrument Data',
        input_properties => [qw/ analysis_project instrument_data_properties downsample_ratio library library_name sample_name source_paths working_directory /],
        output_properties => [qw/ instrument_data /],
    );
    $self->_workflow($workflow);

    my $retrieve_source_path_op = $self->_add_retrieve_source_path_op_to_workflow($workflow->get_input_connector);
    return if not $retrieve_source_path_op;

    my $verify_not_imported_op = $self->_add_verify_not_imported_op_to_workflow($retrieve_source_path_op);
    return if not $verify_not_imported_op;
    $self->_verify_not_imported_op($verify_not_imported_op);

    my @steps = $self->_resolve_workflow_steps;
    my $previous_op = $verify_not_imported_op;
    for my $step ( @steps ) {
        $step =~ s/ /_/g;
        my $add_step_method = '_add_'.$step.'_op_to_workflow';
        $previous_op = $self->$add_step_method($previous_op);
        return if not $previous_op;
    }

    my $create_instdata_and_copy_bam_op = $self->_add_create_instdata_and_copy_bam_op_to_workflow($previous_op);
    return if not $create_instdata_and_copy_bam_op;

    return $workflow;
}

sub _resolve_workflow_steps {
    my $self = shift;

    my $steps_method = '_steps_to_build_workflow_for_'.$self->work_flow_inputs->format;
    my @steps = $self->$steps_method;
    return @steps if not $self->work_flow_inputs->instrument_data_properties->{downsample_ratio};

    my $idx = List::MoreUtils::firstidx(sub{ $_ eq 'sanitize bam' }, @steps);
    if ( not $idx ) {
        $idx = List::MoreUtils::firstidx(sub{ $_ eq 'sort bam' }, @steps);
    }
    splice(@steps, $idx + 1, 0, 'downsample bam');

    return @steps;
}

sub _steps_to_build_workflow_for_bam {
    my $self = shift;

    return (
        'sort bam', 'sanitize bam', 'split bam by rg',
    );
}

sub _steps_to_build_workflow_for_fastq {
    my $self = shift;

    return (
       'fastqs to bam', 'sort bam',
    );
}

sub _steps_to_build_workflow_for_fastq_archive {
    my $self = shift;

    return (
       'archive to fastqs', 'fastqs to bam', 'sort bam',
    );
}

sub _steps_to_build_workflow_for_sra {
    my $self = shift;

    return (
        'sra to bam', 'sort bam', 'sanitize bam', 'split bam by rg',
    );
}

sub _add_retrieve_source_path_op_to_workflow {
    my ($self, $previous_op) = @_;

    my @op_name_parts = (qw/ retrieve source path from /);
    push @op_name_parts, $self->work_flow_inputs->source_files->retrieval_method;
    my $workflow = $self->_workflow;
    my $retrieve_source_path_op = $self->helpers->add_operation_to_workflow_by_name($workflow, join(' ', @op_name_parts));
    $workflow->add_link(
        left_operation => $workflow->get_input_connector,
        left_property => 'working_directory',
        right_operation => $retrieve_source_path_op,
        right_property => 'working_directory',
    );
    $workflow->add_link(
        left_operation => $previous_op,
        left_property => 'source_paths',
        right_operation => $retrieve_source_path_op,
        right_property => 'source_path',
    );
    $retrieve_source_path_op->parallel_by('source_path') if $self->work_flow_inputs->source_files->paths > 1;

    return $retrieve_source_path_op;
}

sub _add_verify_not_imported_op_to_workflow {
    my ($self, $retrieve_source_path_op) = @_;

    die 'No retrieve source files operation given!' if not $retrieve_source_path_op;

    my $workflow = $self->_workflow;
    my $verify_not_imported_op = $self->helpers->add_operation_to_workflow_by_name($workflow, 'verify not imported');
    $workflow->add_link(
        left_operation => $workflow->get_input_connector,
        left_property => 'working_directory',
        right_operation => $verify_not_imported_op,
        right_property => 'working_directory',
    );
    $workflow->add_link(
        left_operation => $retrieve_source_path_op,
        left_property => 'destination_path',
        right_operation => $verify_not_imported_op,
        right_property => 'source_path',
   );
   $verify_not_imported_op->parallel_by('source_path') if $self->work_flow_inputs->source_files->paths > 1;

    return $verify_not_imported_op;
}

sub _add_sra_to_bam_op_to_workflow {
    my $self = shift;

    my $workflow = $self->_workflow;
    my $sra_to_bam_op = $self->helpers->add_operation_to_workflow_by_name($workflow, 'sra to bam');
    for my $property_mapping ( [qw/ working_directory working_directory /], [qw/ source_path sra_path /] ) {
        my ($left_property, $right_property) = @$property_mapping;
        $workflow->add_link(
            left_operation => $self->_verify_not_imported_op,
            left_property => $left_property,
            right_operation => $sra_to_bam_op,
            right_property => $right_property,
        );
    }

    return $sra_to_bam_op;
}

sub _add_archive_to_fastqs_op_to_workflow {
    my $self = shift;

    my $archive_to_fastqs_op = $self->helpers->add_operation_to_workflow_by_name($self->_workflow, 'archive to fastqs');
    return if not $archive_to_fastqs_op;
    $self->_workflow->add_link(
        left_operation => $self->_workflow->get_input_connector,
        left_property => 'working_directory',
        right_operation => $archive_to_fastqs_op,
        right_property => 'working_directory',
    );
    $self->_workflow->add_link(
        left_operation => $self->_verify_not_imported_op,
        left_property => 'source_path',
        right_operation => $archive_to_fastqs_op,
        right_property => 'archive_path',
    );

    return $archive_to_fastqs_op;
}

sub _add_fastqs_to_bam_op_to_workflow {
    my ($self, $previous_op) = @_;

    die 'No previous operation given!' if not $previous_op;

    my $fastqs_to_bam_op = $self->helpers->add_operation_to_workflow_by_name($self->_workflow, 'fastqs to bam');
    return if not $fastqs_to_bam_op;

    for my $property (qw/ working_directory library_name sample_name /) {
        $self->_workflow->add_link(
            left_operation => $self->_workflow->get_input_connector,
            left_property => $property,
            right_operation => $fastqs_to_bam_op,
            right_property => $property,
        );
    }
    $self->_workflow->add_link(
        left_operation => $previous_op,
        left_property => ( $previous_op->name eq 'verify not imported' ) # not ideal...
        ? 'source_path'
        : 'fastq_paths',
        right_operation => $fastqs_to_bam_op,
        right_property => 'fastq_paths',
    );

    return $fastqs_to_bam_op;
}

sub _add_sanitize_bam_op_to_workflow {
    my ($self, $previous_op) = @_;

    die 'No previous operation given to _add_sanitize_bam_op_to_workflow!' if not $previous_op;

    my $sanitize_bam_op = $self->helpers->add_operation_to_workflow_by_name($self->_workflow, 'sanitize bam');
    return if not $sanitize_bam_op;
    $self->_workflow->add_link(
        left_operation => $previous_op,
        left_property => 'output_bam_path',
        right_operation => $sanitize_bam_op,
        right_property => 'bam_path',
    );

    return $sanitize_bam_op;
}

sub _add_sort_bam_op_to_workflow {
    my ($self, $previous_op) = @_;

    die 'No previous op given to _add_sort_bam_op_to_workflow!' if not $previous_op;

    my $sort_bam_op = $self->helpers->add_operation_to_workflow_by_name($self->_workflow, 'sort bam');
    $self->_workflow->add_link(
        left_operation => $previous_op,
        left_property => ( $previous_op->operation_type->command_class_name->can('output_bam_path') )
        ? 'output_bam_path'
        : 'source_path',
        right_operation => $sort_bam_op,
        right_property => 'bam_path',
    );

    return $sort_bam_op;
}

sub _add_downsample_bam_op_to_workflow {
    my ($self, $previous_op) = @_;

    die 'No previous op given to _add_downsample_bam_op_to_workflow!' if not $previous_op;

    my $downsample_bam_op = $self->helpers->add_operation_to_workflow_by_name($self->_workflow, 'downsample bam');
    return if not $downsample_bam_op;

    $self->_workflow->add_link(
        left_operation => $self->_workflow->get_input_connector,
        left_property => 'downsample_ratio',
        right_operation => $downsample_bam_op,
        right_property => 'downsample_ratio',
    );
    $self->_workflow->add_link(
        left_operation => $previous_op,
        left_property => 'output_bam_path',
        right_operation => $downsample_bam_op,
        right_property => 'bam_path',
    );

    return $downsample_bam_op;
}

sub _add_split_bam_by_rg_op_to_workflow {
    my ($self, $previous_op) = @_;

    die 'No previous op given to _add_split_bam_by_rg_op_to_workflow!' if not $previous_op;

    my $split_bam_by_rg_op = $self->helpers->add_operation_to_workflow_by_name($self->_workflow, 'split bam by read group');
    $self->_workflow->add_link(
        left_operation => $previous_op,
        left_property => 'output_bam_path',
        right_operation => $split_bam_by_rg_op,
        right_property => 'bam_path',
    );

    return $split_bam_by_rg_op;
}

sub _add_create_instdata_and_copy_bam_op_to_workflow {
    my ($self, $previous_op) = @_;

    die 'No previous op given to _add_create_instdata_and_copy_bam_op_to_workflow!' if not $previous_op;

    my $workflow = $self->_workflow;
    my $create_instdata_and_copy_bam_op = $self->helpers->add_operation_to_workflow_by_name($workflow, 'create instrument data and copy bam');
    for my $property (qw/ analysis_project library instrument_data_properties /) {
        $workflow->add_link(
            left_operation => $workflow->get_input_connector,
            left_property => $property,
            right_operation => $create_instdata_and_copy_bam_op,
            right_property => $property,
        );
    }

    $workflow->add_link(
        left_operation => $previous_op,
        left_property => ( $previous_op->name eq 'sort bam' ) # not ideal...
        ? 'output_bam_path'
        : 'output_bam_paths',
        right_operation => $create_instdata_and_copy_bam_op,
        right_property => 'bam_paths',
    );

    $workflow->add_link(
        left_operation => $self->_verify_not_imported_op,
        left_property => 'source_md5',
        right_operation => $create_instdata_and_copy_bam_op,
        right_property => 'source_md5s',
    );
    $create_instdata_and_copy_bam_op->parallel_by('bam_path');

    $workflow->add_link(
        left_operation => $create_instdata_and_copy_bam_op,
        left_property => 'instrument_data',
        right_operation => $workflow->get_output_connector,
        right_property => 'instrument_data',
    );

    return $create_instdata_and_copy_bam_op;
}

1;

