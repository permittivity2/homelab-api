use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::DriveWebUI',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Web interface for Homelab Drive',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious' => '9.0',
        'YAML::XS'    => '0.0',
    },
    TEST_REQUIRES => {
        'Test::More'  => '1.3',
        'Test::Mojo'  => '0.0',
    },
    EXE_FILES    => ['script/homelab-drive-web-ui'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-DriveUI-* *.deb *.changes *.buildinfo' },
);
