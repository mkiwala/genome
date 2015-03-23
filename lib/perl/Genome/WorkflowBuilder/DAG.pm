package Genome::WorkflowBuilder::DAG;

use strict;
use warnings;

use Genome;
use Params::Validate qw(:types);
use Set::Scalar qw();
use JSON;
use List::MoreUtils qw();


class Genome::WorkflowBuilder::DAG {
    is => 'Genome::WorkflowBuilder::Detail::Operation',

    has => [
        operations => {
            is => 'ARRAY',
            default => [],
            doc => 'Genome::WorkflowBuilder::Detail::Operation objects',
        },

        links => {
            is => 'ARRAY',
            default => [],
            doc => 'Genome::WorkflowBuilder::Link objects',
        },

        log_dir => {
            is => 'Text',
            is_optional => 1,
        },
    ],
};

sub add_operation {
    my ($self, $op) = Params::Validate::validate_pos(@_, 1, {type => OBJECT});
    push @{$self->operations}, $op;

    my %constant_values = %{$op->constant_values};
    while (my ($constant_name, $value) = each %constant_values) {
        my $input_property = sprintf('%s.%s', $op->name, $constant_name);
        $self->connect_input(
            input_property => $input_property,
            destination => $op,
            destination_property => $constant_name,
        );
        $self->declare_constant($input_property => $value);
    }

    return $op;
}

sub add_link {
    my ($self, $link) = Params::Validate::validate_pos(@_, 1, 1);
    push @{$self->links}, $link;
    return $link;
}

# ------------------------------------------------------------------------------
# Public Methods
# ------------------------------------------------------------------------------

sub execute {
    my $self = shift;

    my %p = Params::Validate::validate(@_, {
        inputs => {type => HASHREF},
    });

    my $inputs = {%{$self->constant_values}, %{$p{inputs}}};

    my $backend = $ENV{GENOME_WORKFLOW_BUILDER_BACKEND};
    if ($backend eq 'ptero') {
        return $self->_execute_with_ptero($inputs);

    } elsif ($backend eq 'workflow') {
        return $self->_execute_with_workflow($inputs);

    } else {
        die $self->error_message("Unknown backend specified: %s", $backend);
    }
}

sub _execute_with_workflow {
    require Workflow::Simple;

    my ($self, $inputs) = @_;

    my $result = Workflow::Simple::run_workflow_lsf($self->get_xml, %$inputs);
    unless (defined($result)) {
        die $self->error_message(
            "Workflow failed with these errors: %s",
            Data::Dumper::Dumper(map {$_->error} @Workflow::Simple::ERROR)
        );
    }
    return $result;
}

sub _execute_with_ptero {
    my ($self, $inputs) = @_;

    my $wf_builder = $self->get_ptero_builder($self->name);

    my $wf_proxy = $wf_builder->submit( inputs => $inputs );
    $wf_proxy->wait;

    if ($wf_proxy->has_succeeded) {
        return $wf_proxy->outputs;
    }
    else {
        die $self->error_message('PTero workflow (%s) did not succeed',
            $wf_proxy->url);
    }
}

sub get_ptero_builder {
    require Ptero::Builder::Workflow;

    my $self = shift;
    my $name = shift;

    $self->validate;

    my $dag_method = Ptero::Builder::Workflow->new(name => $name || 'root');

    for my $operation (@{$self->operations}) {
        $dag_method->_add_task($operation->get_ptero_builder_task);
    }

    for my $link (@{$self->links}) {
        $link->validate;
        $dag_method->link_tasks(
            source => $link->source_operation_name,
            source_property => $link->source_property,
            destination => $link->destination_operation_name,
            destination_property => $link->destination_property,
        );
    }

    return $dag_method;
}

sub get_ptero_builder_task {
    require Ptero::Builder::Detail::Workflow::Task;

    my $self = shift;

    $self->validate;

    my %params = (
        name => $self->name,
        methods => [
            $self->get_ptero_builder,
        ],
    );
    if (defined $self->parallel_by) {
        $params{parallel_by} = $self->parallel_by;
    }
    return Ptero::Builder::Detail::Workflow::Task->new(%params);
}


sub create_link {
    my $self = shift;
    $self->add_link(Genome::WorkflowBuilder::Link->create(@_));
    return;
}

sub connect_input {
    my $self = shift;
    my %args = Params::Validate::validate(@_, {
            input_property => { type => Params::Validate::SCALAR },
            destination => { type => Params::Validate::OBJECT },
            destination_property => { type => Params::Validate::SCALAR },
    });

    $self->add_link(Genome::WorkflowBuilder::Link->create(
        source_property => $args{input_property},
        destination => $args{destination},
        destination_property => $args{destination_property},
    ));
    return;
}

sub connect_output {
    my $self = shift;
    my %args = Params::Validate::validate(@_, {
            source => { type => Params::Validate::OBJECT },
            source_property => { type => Params::Validate::SCALAR },
            output_property => { type => Params::Validate::SCALAR },
    });

    $self->add_link(Genome::WorkflowBuilder::Link->create(
        source => $args{source},
        source_property => $args{source_property},
        destination_property => $args{output_property},
    ));
    return;
}

sub operation_named {
    my ($self, $name) = @_;

    for my $op (@{$self->operations}) {
        if ($op->name eq $name) {
            return $op
        }
    }

    return;
}

sub is_input_property {
    my ($self, $property_name) = @_;

    return List::MoreUtils::any {$property_name eq $_} $self->input_properties;
}

sub is_output_property {
    my ($self, $property_name) = @_;

    return List::MoreUtils::any {$property_name eq $_} $self->output_properties;
}

sub is_many_property {
    my ($self, $property_name) = @_;
    # XXX There may not be an easy way to determine this.
    return;
}


# ------------------------------------------------------------------------------
# Inherited Methods
# ------------------------------------------------------------------------------

sub from_xml_element {
    my ($class, $element) = @_;

    my $self = $class->create(
        name => $element->getAttribute('name'),
        log_dir => $element->getAttribute('logDir'),
        parallel_by => $element->getAttribute('parallelBy'),
    );

    $self->_add_operations_from_xml_element($element);
    $self->_add_links_from_xml_element($element);

    return $self;
}


sub get_xml_element {
    my $self = shift;

    my $element = $self->SUPER::get_xml_element($self);

    if (defined($self->log_dir)) {
        $element->setAttribute('logDir', $self->log_dir);
    }

    map {$element->addChild($_->get_xml_element)}
        sort {$a->name cmp $b->name} @{$self->operations};
    map {$element->addChild($_->get_xml_element)}
        sort {$a->sort_key cmp $b->sort_key} @{$self->links};

    return $element;
}

sub input_properties {
    my $self = shift;
    return sort $self->_property_names_from_links('external_input',
        'source_property');
}

sub output_properties {
    my $self = shift;
    return sort $self->_property_names_from_links('external_output',
        'destination_property');
}

sub validate {
    my $self = shift;

    $self->SUPER::validate;

    $self->_validate_operation_names_are_unique;
    $self->_validate_linked_operation_ownership;
    $self->_validate_mandatory_inputs;
    $self->_validate_non_conflicting_inputs;

    for my $op (@{$self->operations}) {
        $op->validate;
    }

    for my $link (@{$self->links}) {
        $link->validate;
    }

    return;
}


# ------------------------------------------------------------------------------
# Private Methods
# ------------------------------------------------------------------------------

sub _add_operations_from_xml_element {
    my ($self, $element) = @_;

    my $nodelist = $element->find('operation');
    for my $node ($nodelist->get_nodelist) {
        my $op = Genome::WorkflowBuilder::Detail::Operation->from_xml_element($node);
        $self->add_operation($op);
    }
}

sub _add_links_from_xml_element {
    my ($self, $element) = @_;

    my $nodelist = $element->find('link');
    for my $node ($nodelist->get_nodelist) {
        my $source_op = $self->operation_named(
                $node->getAttribute('fromOperation'));
        my $destination_op = $self->operation_named(
                $node->getAttribute('toOperation'));

        my %link_params = (
            source_property => $node->getAttribute('fromProperty'),
            destination_property => $node->getAttribute('toProperty'),
        );
        if (defined($source_op)) {
            $link_params{source} = $source_op;
        }
        if (defined($destination_op)) {
            $link_params{destination} = $destination_op;
        }
        my $link = Genome::WorkflowBuilder::Link->create(%link_params);
        $self->add_link($link);
    }
}

sub _property_names_from_links {
    my ($self, $query_name, $property_holder) = @_;

    my $property_names = new Set::Scalar;

    for my $link (@{$self->links}) {
        if ($link->$query_name) {
            $property_names->insert($link->$property_holder);
        }
    }
    return @{$property_names};
}

sub _validate_operation_names_are_unique {
    my $self = shift;

    my $operation_names = new Set::Scalar;
    for my $op (@{$self->operations}) {
        if ($operation_names->contains($op->name)) {
            die $self->error_message(sprintf(
                    "Workflow DAG '%s' contains multiple operations named '%s'",
                    $self->name, $op->name));
        }
        $operation_names->insert($op->name);
    }

    return;
}

sub _validate_linked_operation_ownership {
    my $self = shift;

    my %operations_hash;
    for my $op (@{$self->operations}) {$operations_hash{$op} = 1;}

    for my $link (@{$self->links}) {
        $self->_validate_operation_ownership($link->source, \%operations_hash);
        $self->_validate_operation_ownership($link->destination,
            \%operations_hash);
    }
    return;
}

sub _validate_operation_ownership {
    my ($self, $op, $operations_hash) = @_;

    if (defined($op)) {
        unless ($operations_hash->{$op}) {
            die $self->error_message(sprintf(
                    "Unowned operation (%s) linked in DAG (%s)",
                    $op->name, $self->name,
            ));
        }
    }
}

sub _validate_mandatory_inputs {
    my $self = shift;

    my $mandatory_inputs = $self->_get_mandatory_inputs;
    for my $link (@{$self->links}) {
        my $ei = $self->_encode_input($link->destination_operation_name,
            $link->destination_property);
        if ($mandatory_inputs->contains($ei)) {
            $mandatory_inputs->delete($ei);
        }
    }

    unless ($mandatory_inputs->is_empty) {
        die $self->error_message(sprintf(
            "%d mandatory input(s) missing in DAG: %s",
            $mandatory_inputs->size, $mandatory_inputs
        ));
    }
}

sub _get_mandatory_inputs {
    my $self = shift;

    my $result = new Set::Scalar;

    for my $op (@{$self->operations}) {
        for my $prop_name ($op->input_properties) {
            $result->insert($self->_encode_input($op->name, $prop_name));
        }
    }

    return $result;
}

sub _encode_input {
    my ($self, $op_name, $property_name) = @_;
    my $js = JSON->new->allow_nonref;

    return $js->canonical->encode({
        operation_name => $op_name,
        property_name => $property_name,
    });
}

sub _validate_non_conflicting_inputs {
    my $self = shift;

    my $encoded_inputs = new Set::Scalar;
    for my $link (@{$self->links}) {
        my $ei = $self->_encode_input($link->destination_operation_name,
            $link->destination_property);
        if ($encoded_inputs->contains($ei)) {
            die $self->error_message(sprintf(
"Conflicting input to '%s' on (%s) found.  One link is from '%s' on (%s)",
                $link->destination_property, $link->destination_operation_name,
                $link->source_property, $link->source_operation_name
            ));
        }
        $encoded_inputs->insert($ei);
    }
}

1;
