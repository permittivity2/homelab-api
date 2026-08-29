package Homelab::Backup;

use strict;
use warnings;

# Control-plane backend for homelab-backup-client/-server. Wired identically
# to Homelab::Drive/Homelab::Mail (Homelab::Backup->new($db, $config)).
#
# This module owns all Postgres access for the `backup` schema (migration
# 011-backup-schema.sql) on behalf of both packages -- neither
# homelab-backup-client nor homelab-backup-server ever connects to Postgres
# directly; they talk to homelab-cli, which talks to the routes in API.pm
# that call into here.
#
# Every public method below runs its DB work through _safe(), which turns
# "the backup schema/tables don't exist yet" (migrations/011 not applied)
# into a distinguishable { error, missing_schema => 1 } result instead of a
# bare 500 -- this is what lets `homelab-backup-server setup` fail with an
# actionable message pointing at the migration files, rather than an opaque
# error, per the redesign plan's explicit resolution of "no runtime DDL from
# a request handler, ever."

my @VALID_BACKUP_MODES = qw(full_host local_only homelab_only specific);
my @VALID_RUN_STATUSES = qw(success warning failure);
my @VALID_CHECK_STATUSES = qw(success failure);

sub new {
    my ($class, $db, $config) = @_;
    return bless { db => $db, config => $config }, $class;
}

sub _safe {
    my ($self, $code) = @_;
    my $result = eval { $code->() };
    if ($@) {
        my $err = "$@";
        if ($err =~ /relation "backup\.\w+" does not exist/ || $err =~ /schema "backup" does not exist/) {
            return { error => 'Backup schema not installed — apply migrations/011-backup-schema.sql', missing_schema => 1 };
        }
        return { error => 'Internal error' };
    }
    return $result;
}

sub _valid_identifier {
    my ($identifier) = @_;
    return 0 unless defined $identifier && length $identifier;
    return $identifier =~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ ? 1 : 0;
}

# Records a pending enrollment request. Idempotent: a retried submission for
# the same (identifier, pubkey, action) while one is still pending returns
# the same enrollment_id instead of creating a duplicate row.
sub enroll {
    my ($self, $identifier, $hostname, $pubkey) = @_;
    return { error => 'identifier, hostname, and pubkey are required' }
        unless $identifier && $hostname && $pubkey;
    return { error => 'Invalid identifier' } unless _valid_identifier($identifier);

    return $self->_safe(sub {
        my $row = $self->{db}->query_row(
            "INSERT INTO backup.enrollment_requests (identifier, hostname, pubkey, action)
             VALUES (?, ?, ?, 'enroll')
             ON CONFLICT (identifier, pubkey, action) WHERE status = 'pending' DO NOTHING
             RETURNING id"
            , $identifier, $hostname, $pubkey
        );
        unless ($row) {
            $row = $self->{db}->query_row(
                "SELECT id FROM backup.enrollment_requests
                 WHERE identifier = ? AND pubkey = ? AND action = 'enroll' AND status = 'pending'",
                $identifier, $pubkey
            );
        }
        return { success => 1, enrollment_id => $row->{id}, status => 'pending' };
    });
}

sub request_revoke {
    my ($self, $identifier) = @_;
    return { error => 'identifier is required' } unless $identifier;

    return $self->_safe(sub {
        my $host = $self->{db}->query_row(
            "SELECT hostname, pubkey FROM backup.hosts WHERE identifier = ? AND status = 'active'",
            $identifier
        );
        return { error => 'Host not found or already revoked' } unless $host;

        my $row = $self->{db}->query_row(
            "INSERT INTO backup.enrollment_requests (identifier, hostname, pubkey, action)
             VALUES (?, ?, ?, 'revoke')
             ON CONFLICT (identifier, pubkey, action) WHERE status = 'pending' DO NOTHING
             RETURNING id",
            $identifier, $host->{hostname}, $host->{pubkey}
        );
        unless ($row) {
            $row = $self->{db}->query_row(
                "SELECT id FROM backup.enrollment_requests
                 WHERE identifier = ? AND pubkey = ? AND action = 'revoke' AND status = 'pending'",
                $identifier, $host->{pubkey}
            );
        }
        return { success => 1, enrollment_id => $row->{id} };
    });
}

sub list_pending_enrollments {
    my ($self, $action) = @_;

    return $self->_safe(sub {
        my $rows;
        if ($action) {
            $rows = $self->{db}->query_rows(
                "SELECT id, identifier, hostname, pubkey, action, requested_at
                 FROM backup.enrollment_requests
                 WHERE status = 'pending' AND action = ?
                 ORDER BY requested_at",
                $action
            );
        }
        else {
            $rows = $self->{db}->query_rows(
                "SELECT id, identifier, hostname, pubkey, action, requested_at
                 FROM backup.enrollment_requests
                 WHERE status = 'pending'
                 ORDER BY requested_at"
            );
        }
        return { success => 1, enrollments => $rows };
    });
}

# Marks a pending enrollment/revocation as applied. For an 'enroll' ack,
# $repo (optional {ssh_user, server, location}) also upserts the host's repo
# record so report_run/report_check can later resolve a repo_id for it.
sub ack_enrollment {
    my ($self, $id, $repo) = @_;
    return { error => 'id is required' } unless $id;

    return $self->_safe(sub {
        my $row = $self->{db}->query_row(
            "SELECT id, identifier, hostname, pubkey, action FROM backup.enrollment_requests
             WHERE id = ? AND status = 'pending'", $id
        );
        return { error => 'Enrollment request not found or already acked' } unless $row;

        if ($row->{action} eq 'enroll') {
            my $host = $self->{db}->query_row(
                "INSERT INTO backup.hosts (identifier, hostname, pubkey, status, last_seen_at)
                 VALUES (?, ?, ?, 'active', now())
                 ON CONFLICT (identifier) DO UPDATE SET
                     hostname = EXCLUDED.hostname, pubkey = EXCLUDED.pubkey,
                     status = 'active', last_seen_at = now()
                 RETURNING id",
                $row->{identifier}, $row->{hostname}, $row->{pubkey}
            );
            if ($repo && $repo->{ssh_user} && $repo->{server} && $repo->{location}) {
                $self->{db}->query(
                    "INSERT INTO backup.repos (host_id, ssh_user, server, location)
                     VALUES (?, ?, ?, ?)
                     ON CONFLICT (host_id, ssh_user, server, location) DO NOTHING",
                    $host->{id}, $repo->{ssh_user}, $repo->{server}, $repo->{location}
                );
            }
        }
        else {
            $self->{db}->query(
                "UPDATE backup.hosts SET status = 'revoked' WHERE identifier = ?",
                $row->{identifier}
            );
        }

        $self->{db}->query(
            "UPDATE backup.enrollment_requests SET status = 'acked', acked_at = now() WHERE id = ?",
            $id
        );
        return { success => 1 };
    });
}

sub _repo_id_for_identifier {
    my ($self, $identifier) = @_;
    my $row = $self->{db}->query_row(
        "SELECT r.id FROM backup.repos r
         JOIN backup.hosts h ON h.id = r.host_id
         WHERE h.identifier = ?
         ORDER BY r.created_at DESC LIMIT 1",
        $identifier
    );
    return $row ? $row->{id} : undef;
}

sub report_run {
    my ($self, %f) = @_;
    return { error => 'identifier, mode, started_at, finished_at, status are required' }
        unless $f{identifier} && $f{mode} && $f{started_at} && $f{finished_at} && $f{status};
    return { error => 'Invalid mode' } unless grep { $_ eq $f{mode} } @VALID_BACKUP_MODES;
    return { error => 'Invalid status' } unless grep { $_ eq $f{status} } @VALID_RUN_STATUSES;

    return $self->_safe(sub {
        my $repo_id = $self->_repo_id_for_identifier($f{identifier});
        return { error => 'No repo registered for host' } unless $repo_id;

        my $row = $self->{db}->query_row(
            "INSERT INTO backup.backup_runs
                (repo_id, mode, archive_name, started_at, finished_at, status,
                 original_size_bytes, compressed_size_bytes, deduplicated_size_bytes,
                 file_count, error_message)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             RETURNING id",
            $repo_id, $f{mode}, $f{archive_name}, $f{started_at}, $f{finished_at}, $f{status},
            $f{original_size_bytes}, $f{compressed_size_bytes}, $f{deduplicated_size_bytes},
            $f{file_count}, $f{error_message}
        );
        return { success => 1, run_id => $row->{id} };
    });
}

sub report_check {
    my ($self, %f) = @_;
    return { error => 'identifier, started_at, finished_at, status are required' }
        unless $f{identifier} && $f{started_at} && $f{finished_at} && $f{status};
    return { error => 'Invalid status' } unless grep { $_ eq $f{status} } @VALID_CHECK_STATUSES;

    return $self->_safe(sub {
        my $repo_id = $self->_repo_id_for_identifier($f{identifier});
        return { error => 'No repo registered for host' } unless $repo_id;

        my $row = $self->{db}->query_row(
            "INSERT INTO backup.check_runs (repo_id, started_at, finished_at, status, error_message)
             VALUES (?, ?, ?, ?, ?)
             RETURNING id",
            $repo_id, $f{started_at}, $f{finished_at}, $f{status}, $f{error_message}
        );
        return { success => 1, check_id => $row->{id} };
    });
}

sub list_hosts {
    my ($self) = @_;
    return $self->_safe(sub {
        my $rows = $self->{db}->query_rows(
            'SELECT identifier, hostname, status, first_seen_at, last_seen_at
             FROM backup.hosts ORDER BY identifier'
        );
        return { success => 1, hosts => $rows };
    });
}

sub list_repos {
    my ($self, $identifier) = @_;
    return $self->_safe(sub {
        my $rows;
        if ($identifier) {
            $rows = $self->{db}->query_rows(
                "SELECT h.identifier, r.ssh_user, r.server, r.location, r.created_at
                 FROM backup.repos r JOIN backup.hosts h ON h.id = r.host_id
                 WHERE h.identifier = ? ORDER BY r.created_at",
                $identifier
            );
        }
        else {
            $rows = $self->{db}->query_rows(
                "SELECT h.identifier, r.ssh_user, r.server, r.location, r.created_at
                 FROM backup.repos r JOIN backup.hosts h ON h.id = r.host_id
                 ORDER BY h.identifier, r.created_at"
            );
        }
        return { success => 1, repos => $rows };
    });
}

sub host_runs {
    my ($self, $identifier, $limit) = @_;
    $limit = (defined $limit && $limit =~ /^\d+$/ && $limit > 0) ? $limit : 20;

    return $self->_safe(sub {
        my $rows = $self->{db}->query_rows(
            "SELECT br.mode, br.archive_name, br.started_at, br.finished_at, br.status,
                    br.original_size_bytes, br.compressed_size_bytes, br.deduplicated_size_bytes,
                    br.file_count, br.error_message
             FROM backup.backup_runs br
             JOIN backup.repos r ON r.id = br.repo_id
             JOIN backup.hosts h ON h.id = r.host_id
             WHERE h.identifier = ?
             ORDER BY br.started_at DESC LIMIT ?",
            $identifier, $limit
        );
        return { success => 1, runs => $rows };
    });
}

sub get_server_info {
    my ($self) = @_;
    return $self->_safe(sub {
        my $row = $self->{db}->query_row(
            'SELECT hostname, ssh_user, backup_location FROM backup.server_info WHERE id = 1'
        );
        return { error => 'Server info not configured' } unless $row;
        return { success => 1, %$row };
    });
}

sub set_server_info {
    my ($self, $hostname, $ssh_user, $backup_location) = @_;
    return { error => 'hostname, ssh_user, and backup_location are required' }
        unless $hostname && $ssh_user && $backup_location;

    return $self->_safe(sub {
        $self->{db}->query(
            'INSERT INTO backup.server_info (id, hostname, ssh_user, backup_location, updated_at)
             VALUES (1, ?, ?, ?, now())
             ON CONFLICT (id) DO UPDATE SET
                 hostname = EXCLUDED.hostname, ssh_user = EXCLUDED.ssh_user,
                 backup_location = EXCLUDED.backup_location, updated_at = now()',
            $hostname, $ssh_user, $backup_location
        );
        return { success => 1 };
    });
}

1;
