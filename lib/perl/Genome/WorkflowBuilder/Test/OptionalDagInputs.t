#!/usr/bin/env genome-perl

use strict;
use warnings FATAL => 'all';

use Test::More;
use above 'Genome';
use Genome::Utility::Test qw(compare_ok);

BEGIN {
    $ENV{UR_DBI_NO_COMMIT} = 1;
    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
};

my $code_test_dir = __FILE__ . '.d';

my $valid_workflow_file = File::Spec->join($code_test_dir,
    'valid_workflow.xml');

{
    my $dag = Genome::WorkflowBuilder::DAG->from_xml_filename(
        $valid_workflow_file);
    my $got_xml = Genome::Sys->write_temp_file($dag->get_xml);
    compare_ok($got_xml, $valid_workflow_file,
        "Roundtrip with isOptional works");
}


done_testing();
