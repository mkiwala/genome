package Genome::Model::Tools::Relationship::HeterozygousDominant;

use strict;
use warnings;
use Data::Dumper;
use Genome;
use Genome::Info::IUB;
use Genome::Utility::Vcf qw(open_vcf_file get_vcf_header);
use POSIX;
our $VERSION = '0.01';
use Cwd;
use File::Basename;
use File::Path;

class Genome::Model::Tools::Relationship::HeterozygousDominant {
    is => 'Command',
    has_optional_input => [
    input_vcf=> {
        is=>'Text',
        is_optional=>0,
        doc=>"family/multifamily vcf you want to search for heterozygous dominant mutations",
    },
    vcf_output=>{
        is=>'Text',
        is_optional=>0,
        doc=>"output file of any possible heterozygous sites",
        is_output=>1,
    },
    ped_file=> {
        is=>'Text',
        is_optional=>0,
        doc=>'ped file describing all people in the vcf with affectation status',
    },
    ],
    has_param => [
    lsf_resource => {
        is => 'Text',
        default => "-R 'span[hosts=1] rusage[mem=1000]' -n 4",
    },
    lsf_queue => {
        is => 'Text',
        default => Genome::Config::get('lsf_queue_build_worker'),
    },
    ],
};

sub help_brief {
    "simulates reads and outputs a name sorted bam suitable for import into Genome::Model"
}

sub help_detail {
}

sub execute {
    my $self = shift;

    $DB::single=1;
    unless(-s $self->ped_file) {
        $self->error_message("Ped file not found\n");
        return;
    }
    my $ped_hash = $self->parse_ped($self->ped_file, $self->input_vcf);
#    unless($self->vep_annotation_file && (-s $self->vep_annotation_file)) { ###if we weren't given an annotation file, generate it
#        $self->vep_annotation_file($self->generate_annotation_file($self->input_vcf));
#    }
    my $recessive_vcf = $self->find_dominant_heterozygotes($self->input_vcf, $ped_hash);
    my $out_file = $self->vcf_output;
    `cp $recessive_vcf $out_file`;
    return 1;
}

1;

sub find_indices {
    my ($self, $ped_hash, $type) = @_;
    my @indices;
    for my $key (sort keys %$ped_hash) {
        my $affectation_status = $ped_hash->{$key}->{'affected'};
        if($affectation_status && ($type eq 'affected')) {
            push @indices, $ped_hash->{$key}->{'vcf_index'};
        }
        if(!$affectation_status && ($type eq 'unaffected')) {
            push @indices, $ped_hash->{$key}->{'vcf_index'};
        }
    }
    return @indices;
}

sub is_heterozygous {
    my ($self, $sample) = @_;
    return 0 if ($sample =~m/^\./);
    my (@fields) = split ":", $sample;####assuming GT COMES FIRST.  come back and actually parse format later.
    my ($all1, $all2) = split "[/|]", $fields[0];

    if(($all1 != 0) && ($all2 eq 0)) {
        return $all1;
    }
    if(($all2 !=0) && ($all1 eq 0)) {
        return $all2;
    }
    return 0;
}

sub is_homozygous {
    my ($self, $sample) = @_;
    return 0 if ($sample =~m/^\./);
    my (@fields) = split ":", $sample;####assuming GT COMES FIRST.  come back and actually parse format later.
    my ($all1, $all2) = split "[/|]", $fields[0];
    if(($all1 != 0) && ($all2 eq $all1)) {
        return $all1;
    }
    return 0;
}


sub find_dominant_heterozygotes {
    my ($self, $input_vcf, $ped_hash) = @_;
    my @affecteds = $self->find_indices($ped_hash, 'affected');
    my @unaffecteds = $self->find_indices($ped_hash,'unaffected');
    $DB::single=1;
    my ($output_fh, $output_name) = Genome::Sys->create_temp_file;
    my $header = get_vcf_header($input_vcf);
    $output_fh->print($header);

    my $fh = open_vcf_file($input_vcf);
    while(my $line = $fh->getline) {
        next if $line=~m/^#/;
        chomp($line);
        my ($chr, $pos, $id, $ref, $alt, $qual, $filter, $info, $format, @samples) = split "\t", $line;
        my ($affected_heterzygotes, $unaffected_heterzygotes)=(0,0);
        for my $affected(@affecteds) {
            if(my $allele = $self->is_heterozygous($samples[$affected])) {
                $affected_heterzygotes++;
            }
        }
        for my $unaffected(@unaffecteds) {
            if(my $allele = $self->is_heterozygous($samples[$unaffected])) {
                $unaffected_heterzygotes++;
            }
            elsif($allele = $self->is_homozygous($samples[$unaffected])) {
                $unaffected_heterzygotes++;
            }
        }
        if(($unaffected_heterzygotes == 0) && ($affected_heterzygotes > 0) ) {
            $output_fh->print($line . "\n");
        }
    }
    $output_fh->close;
    return $output_name;
}


sub parse_ped {
    my ($self, $ped_file, $input_vcf) = @_;
    my %ped_hash;
    my $header_lines = get_vcf_header($input_vcf);
    my @header_lines = split("\n", $header_lines);
    my $header_line = $header_lines[-1];
    my ($chr, $pos, $id, $ref, $alt, $qual, $filter, $info, $format, @samples) = split "\t", $header_line;
    for (my $i=0; $i < scalar(@samples); $i++) {
        $ped_hash{$samples[$i]}{vcf_index}=$i;
    }
    my $ped = IO::File->new($ped_file);
    while(my $line = $ped->getline) {
        chomp($line);
        my ($family_id, $person_id, $father_id, $mother_id, $sex, $glf_index, $affectation_status) = split "\t", $line;
        unless(exists($ped_hash{$person_id})) {
            $self->debug_message("$person_id found in ped but not vcf. Person will not be analyzed");
            next;
        }
        if($affectation_status eq 'A') {
            $ped_hash{$person_id}{affected}=1;
        }
        else {
            $ped_hash{$person_id}{affected}=0;
        }

    }
    return \%ped_hash;
}

1;
