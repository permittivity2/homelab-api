use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'Homelab::API',
    VERSION           => '0.1.0',
    ABSTRACT_FROM     => 'lib/Homelab/API.pm',
    AUTHOR            => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE           => 'agpl_3',
    INSTALLDIRS       => 'vendor',
    PREREQ_PM         => {
        'Mojolicious'       => '9.0',
        'Mojo::Pg'          => '4.0',
        'Crypt::JWT'        => '0.0',
        'Crypt::Argon2'     => '0.0',
        'Crypt::URandom'    => '0.0',
        'JSON::XS'          => '4.0',
        'DateTime'          => '1.0',
    },
    TEST_REQUIRES     => {
        'Test::More' => '1.3',
    },
    EXE_FILES         => ['script/homelab-api'],
    DIR               => [],  # don't recurse into drive-web-ui/'s own Makefile.PL
    dist              => {
        COMPRESS => 'gzip -9f',
        SUFFIX   => '.gz',
    },
    clean => {
        FILES => 'Homelab-API-* *.deb *.changes *.buildinfo',
    },
);
