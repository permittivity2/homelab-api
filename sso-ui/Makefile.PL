use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::SsoUI',
    VERSION      => '0.1.0',
    ABSTRACT     => 'SSO login service for Homelab services',
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
    EXE_FILES    => ['script/homelab-sso-ui'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-SsoUI-* *.deb *.changes *.buildinfo' },
);
