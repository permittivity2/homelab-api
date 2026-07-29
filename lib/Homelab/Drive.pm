package Homelab::Drive;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use JSON::XS qw(encode_json decode_json);
use MIME::Types;
use Carp qw(croak);

sub new {
    my ($class, $db, $config) = @_;
    my $self = {
        db               => $db,
        drive_path       => $config->{storage}{drive_path},
        max_file_size_mb => $config->{storage}{max_file_size_mb} // 100,
    };
    return bless $self, $class;
}

sub _user_id {
    my ($self, $email) = @_;
    return undef unless $email;
    my ($username, $domain) = split /@/, $email;
    return undef unless $username && $domain;
    my $user = $self->{db}->query_row(
        'SELECT id FROM dovecot.users WHERE username = ? AND domain = ? AND active = ?',
        $username, $domain, 'Y'
    );
    return $user ? $user->{id} : undef;
}

sub _disk_path {
    my ($self, $user_id, $uuid) = @_;
    my $hex = substr($uuid, 0, 2) . '/' . substr($uuid, 2, 2);
    my $path = "$self->{drive_path}/$user_id/$hex/$uuid";
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    return $path;
}

sub _check_quota {
    my ($self, $user_id, $bytes) = @_;
    my $quota = $self->{db}->query_row(
        'SELECT usage_bytes FROM api.drive_quota WHERE user_id = ?',
        $user_id
    );
    my $current = $quota ? $quota->{usage_bytes} : 0;

    my $user = $self->{db}->query_row(
        'SELECT quota_mb FROM dovecot.users WHERE id = ?',
        $user_id
    );
    return (0, "User not found") unless $user;

    my $limit_bytes = ($user->{quota_mb} // 1024) * 1024 * 1024;
    if ($current + $bytes > $limit_bytes) {
        return (0, "Quota exceeded");
    }
    return (1, undef);
}

sub _update_quota {
    my ($self, $user_id, $delta_bytes, $delta_files) = @_;

    my $exists = $self->{db}->query_row(
        'SELECT user_id FROM api.drive_quota WHERE user_id = ?',
        $user_id
    );

    if ($exists) {
        $self->{db}->query(
            'UPDATE api.drive_quota SET usage_bytes = GREATEST(0, usage_bytes + ?), file_count = GREATEST(0, file_count + ?), last_updated = NOW() WHERE user_id = ?',
            $delta_bytes, $delta_files, $user_id
        );
    } else {
        $self->{db}->query(
            'INSERT INTO api.drive_quota (user_id, usage_bytes, file_count) VALUES (?, ?, ?)',
            $user_id, $delta_bytes, $delta_files
        );
    }
}

sub upload {
    my ($self, $email, $file_name, $dir_id, $upload_obj, $declared_size, $mime) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    if ($declared_size > $self->{max_file_size_mb} * 1024 * 1024) {
        return { error => "File exceeds maximum size of $self->{max_file_size_mb} MB" };
    }

    my ($ok, $msg) = $self->_check_quota($user_id, $declared_size);
    return { error => $msg } unless $ok;

    # Generate UUID
    my $uuid_result = $self->{db}->query_row('SELECT gen_random_uuid()::TEXT as uuid');
    my $uuid = $uuid_result->{uuid};

    my $disk_path = $self->_disk_path($user_id, $uuid);
    my $asset     = $upload_obj->asset;
    my $file_size = 0;

    if ($asset->isa('Mojo::Asset::File')) {
        # Large file already spilled to MOJO_TMPDIR on the same NFS mount.
        # Rename is atomic and instant — no copy needed.
        rename $asset->path, $disk_path
            or return { error => "Failed to move upload to final path: $!" };
        $file_size = -s $disk_path;
    } else {
        # Small file still in memory — write directly to final path.
        $asset->move_to($disk_path)
            or return { error => "Failed to write upload to disk: $!" };
        $file_size = -s $disk_path;
    }

    # Auto-rename if a file with this name already exists: file.txt → file (1).txt → file (2).txt ...
    my ($base, $ext) = ($file_name =~ /^(.+?)(\.[^.]+)$/)
                     ? ($1, $2)
                     : ($file_name, '');
    my $counter = 0;
    while ($self->{db}->query_row(
        'SELECT id FROM api.drive_files WHERE user_id = ? AND file_name = ? AND dir_id IS NOT DISTINCT FROM ?',
        $user_id, $file_name, $dir_id
    )) {
        $counter++;
        $file_name = "$base ($counter)$ext";
    }

    my $file = $self->{db}->query_row(
        'INSERT INTO api.drive_files (user_id, file_name, dir_id) VALUES (?, ?, ?) RETURNING id',
        $user_id, $file_name, $dir_id
    );
    my $file_id = $file->{id};

    # Insert version record (sha256 will be filled by processor)
    my $version = $self->{db}->query_row(
        'INSERT INTO api.drive_versions (file_id, uuid, file_size, mime_type) VALUES (?, ?, ?, ?) '
        . 'RETURNING id, uuid, file_size, mime_type, created_at',
        $file_id, $uuid, $file_size, $mime
    );

    $self->{db}->query(
        'UPDATE api.drive_files SET current_version_id = ?, updated_at = NOW() WHERE id = ?',
        $version->{id}, $file_id
    );

    $self->_update_quota($user_id, $file_size, 1);  # always a new file now

    # Enqueue sha256 task — processor computes it out-of-band
    $self->{db}->query(
        'INSERT INTO api.drive_files_tasks (file_id, task, task_data, status_text) VALUES (?, ?, ?, ?)',
        $file_id, 'sha256',
        encode_json({ version_id => $version->{id}, uuid => $uuid }),
        'queued'
    );

    # Enqueue thumbnail + slide_show_image tasks for image files
    if ($mime && $mime =~ m{^image/}) {
        for my $t (qw(thumbnail slide_show_image)) {
            $self->{db}->query(
                'INSERT INTO api.drive_files_tasks (file_id, task, task_data, status_text) VALUES (?, ?, ?, ?)',
                $file_id, $t,
                encode_json({ version_id => $version->{id}, uuid => $uuid }),
                'queued'
            );
        }
    }

    $version->{file_id} = $file_id;

    return {
        success => 1,
        file => {
            id   => $version->{file_id},
            name => $file_name,
            version => {
                id         => $version->{id},
                uuid       => $version->{uuid},
                size       => $version->{file_size},
                mime       => $version->{mime_type},
                sha256     => undef,   # computed async by processor
                created_at => $version->{created_at},
            }
        }
    };
}

sub download {
    my ($self, $email, $file_id, $version_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $file = $self->{db}->query_row(
        'SELECT id, file_name, current_version_id FROM api.drive_files WHERE id = ? AND user_id = ?',
        $file_id, $user_id
    );
    return { error => 'File not found' } unless $file;

    my $vid = $version_id // $file->{current_version_id};
    my $version = $self->{db}->query_row(
        'SELECT uuid, file_size, mime_type FROM api.drive_versions WHERE id = ? AND file_id = ?',
        $vid, $file_id
    );
    return { error => 'Version not found' } unless $version;

    my $disk_path = $self->_disk_path($user_id, $version->{uuid});
    return { error => 'File not found on disk' } unless -f $disk_path;

    return {
        disk_path => $disk_path,
        file_name => $file->{file_name},
        file_size => $version->{file_size},
        mime_type => $version->{mime_type},
    };
}

sub list_files {
    my ($self, $email, $dir_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $files = $self->{db}->query_rows(
        q{SELECT f.id, f.file_name, f.dir_id, f.status, v.file_size, v.mime_type, v.created_at, v.sha256, v.uuid,
                 COALESCE(
                     json_agg(t.task ORDER BY t.inserted_at) FILTER (WHERE t.id IS NOT NULL),
                     '[]'::json
                 ) AS pending_tasks
          FROM api.drive_files f
          JOIN api.drive_versions v ON f.current_version_id = v.id
          LEFT JOIN api.drive_files_tasks t ON t.file_id = f.id AND t.completed = FALSE
          WHERE f.user_id = ? AND f.dir_id IS NOT DISTINCT FROM ?
          GROUP BY f.id, f.file_name, f.dir_id, f.status, v.file_size, v.mime_type, v.created_at, v.sha256, v.uuid
          ORDER BY f.file_name},
        $user_id, $dir_id
    );

    # Decode json_agg result and rename pending_tasks → tasks
    for my $f (@{ $files // [] }) {
        my $raw = delete $f->{pending_tasks};
        $f->{tasks} = ref $raw ? $raw : decode_json($raw // '[]');
    }

    return { success => 1, files => $files // [] };
}

sub fileinfo {
    my ($self, $email, %opts) = @_;

    my $user_id  = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $startat   = $opts{startat}   // 0;
    my $recursive = $opts{recursive} // 0;
    my $PAGE      = 1000;

    # ── Case A: no path/dir_id → root-level files only (dir_id IS NULL) ─────────
    unless (exists $opts{dir_id} || exists $opts{path}) {

        my $total = $self->{db}->query_row(
            'SELECT COUNT(*) AS n FROM api.drive_files WHERE user_id = ? AND dir_id IS NULL',
            $user_id
        )->{n};

        my $files = $self->{db}->query_rows(
            q{SELECT f.id, f.file_name AS name, f.dir_id, f.status,
                     f.file_name AS path,
                     v.file_size, v.mime_type, v.sha256, v.uuid, v.created_at,
                     COALESCE(json_agg(t.task ORDER BY t.inserted_at) FILTER (WHERE t.id IS NOT NULL),
                         '[]'::json) AS pending_tasks
              FROM api.drive_files f
              JOIN api.drive_versions v ON f.current_version_id = v.id
              LEFT JOIN api.drive_files_tasks t ON t.file_id = f.id AND t.completed = FALSE
              WHERE f.user_id = ? AND f.dir_id IS NULL
              GROUP BY f.id, f.file_name, f.dir_id, f.status,
                       v.file_size, v.mime_type, v.sha256, v.uuid, v.created_at
              ORDER BY f.file_name
              LIMIT ? OFFSET ?},
            $user_id, $PAGE, $startat
        );

        for my $f (@{ $files // [] }) {
            my $raw = delete $f->{pending_tasks};
            $f->{tasks} = ref $raw ? $raw : decode_json($raw // '[]');
        }

        return {
            success => 1,
            total   => $total + 0,
            startat => $startat,
            count   => scalar @{ $files // [] },
            files   => $files // [],
        };
    }

    # ── Case B: path or dir_id → directory listing ────────────────────────────

    # Resolve path → dir_id
    my $dir_id;
    my $resolved_path;

    if (exists $opts{path}) {
        my @parts = grep { length($_) } split /\//, $opts{path};
        if (!@parts) {
            $dir_id       = undef;
            $resolved_path = '/';
        } else {
            my $r = $self->resolve_path($email, $opts{path});
            return { error => $r->{error} } if $r->{error};
            $dir_id        = $r->{dir_id};
            $resolved_path = $r->{path};
        }
    } else {
        $dir_id        = $opts{dir_id};   # undef = root
        if (defined $dir_id) {
            my $d = $self->{db}->query_row(
                'SELECT dir_name FROM api.drive_directories WHERE id = ? AND user_id = ?',
                $dir_id, $user_id
            );
            return { error => 'Directory not found' } unless $d;
            $resolved_path = $d->{dir_name};
        } else {
            $resolved_path = '/';
        }
    }

    my @items;

    if ($recursive) {
        # Recursive: collect all descendant dirs + their files
        my $prefix_sql = ($resolved_path eq '/') ? '' : $resolved_path . '/';
        my $subdirs = $self->{db}->query_rows(
            q{WITH RECURSIVE subdirs AS (
                SELECT id, dir_name,
                       CAST(? AS TEXT) || dir_name AS full_path
                FROM api.drive_directories WHERE user_id = ? AND parent_id IS NOT DISTINCT FROM ?
                UNION ALL
                SELECT d.id, d.dir_name, s.full_path || '/' || d.dir_name
                FROM api.drive_directories d JOIN subdirs s ON d.parent_id = s.id
              )
              SELECT id, dir_name AS name, full_path AS path FROM subdirs ORDER BY full_path},
            $prefix_sql, $user_id, $dir_id
        );

        for my $d (@{ $subdirs // [] }) {
            push @items, { type => 'directory', id => $d->{id}, name => $d->{name}, path => $d->{path} };
        }

        # Fetch files from root dir and each subdir using already-computed paths
        push @items, @{ $self->_files_at_dir($user_id, $dir_id, $prefix_sql) };
        for my $subdir (@{ $subdirs // [] }) {
            push @items, @{ $self->_files_at_dir($user_id, $subdir->{id}, $subdir->{path} . '/') };
        }

    } else {
        # Direct children only
        my $dirs = $self->{db}->query_rows(
            'SELECT id, dir_name AS name FROM api.drive_directories WHERE user_id = ? AND parent_id IS NOT DISTINCT FROM ? ORDER BY dir_name',
            $user_id, $dir_id
        );
        my $parent_prefix = ($resolved_path eq '/') ? '' : $resolved_path . '/';
        for my $d (@{ $dirs // [] }) {
            push @items, { type => 'directory', id => $d->{id}, name => $d->{name}, path => $parent_prefix . $d->{name} };
        }

        my $files = $self->_files_at_dir($user_id, $dir_id, $parent_prefix);
        push @items, @$files;
    }

    my $total   = scalar @items;
    my @page    = grep { defined } @items[$startat .. ($startat + $PAGE - 1)];

    return {
        success   => 1,
        path      => $resolved_path,
        dir_id    => $dir_id,
        recursive => $recursive ? 1 : 0,
        total     => $total,
        startat   => $startat,
        count     => scalar @page,
        items     => \@page,
    };
}

sub _files_at_dir {
    my ($self, $user_id, $dir_id, $prefix) = @_;

    my $files = $self->{db}->query_rows(
        q{SELECT f.id, f.file_name AS name, f.dir_id, f.status,
                 v.file_size, v.mime_type, v.sha256, v.uuid, v.created_at,
                 COALESCE(json_agg(t.task ORDER BY t.inserted_at) FILTER (WHERE t.id IS NOT NULL),
                     '[]'::json) AS pending_tasks
          FROM api.drive_files f
          JOIN api.drive_versions v ON f.current_version_id = v.id
          LEFT JOIN api.drive_files_tasks t ON t.file_id = f.id AND t.completed = FALSE
          WHERE f.user_id = ? AND f.dir_id IS NOT DISTINCT FROM ?
          GROUP BY f.id, f.file_name, f.dir_id, f.status,
                   v.file_size, v.mime_type, v.sha256, v.uuid, v.created_at
          ORDER BY f.file_name},
        $user_id, $dir_id
    );

    my @result;
    for my $f (@{ $files // [] }) {
        my $raw = delete $f->{pending_tasks};
        $f->{tasks} = ref $raw ? $raw : decode_json($raw // '[]');
        $f->{type}  = 'file';
        $f->{path}  = $prefix . $f->{name};
        push @result, $f;
    }
    return \@result;
}

sub _files_in_dirs {
    my ($self, $user_id, $dir_ids, $root_dir_id, $root_path) = @_;

    # Build full path for each file using a recursive CTE anchored at root_dir_id
    my $prefix = ($root_path eq '/') ? '' : $root_path . '/';

    my $files = $self->{db}->query_rows(
        q{WITH RECURSIVE dir_path AS (
            SELECT id, dir_name AS full_path
            FROM api.drive_directories WHERE id = ? AND user_id = ?
            UNION ALL
            SELECT d.id, dp.full_path || '/' || d.dir_name
            FROM api.drive_directories d JOIN dir_path dp ON d.parent_id = dp.id
          )
          SELECT f.id, f.file_name AS name, f.dir_id, f.status,
                 COALESCE(dp.full_path || '/' || f.file_name, f.file_name) AS rel_path,
                 v.file_size, v.mime_type, v.sha256, v.created_at,
                 COALESCE(json_agg(t.task ORDER BY t.inserted_at) FILTER (WHERE t.id IS NOT NULL),
                     '[]'::json) AS pending_tasks
          FROM api.drive_files f
          JOIN api.drive_versions v ON f.current_version_id = v.id
          LEFT JOIN dir_path dp ON f.dir_id = dp.id
          LEFT JOIN api.drive_files_tasks t ON t.file_id = f.id AND t.completed = FALSE
          WHERE f.user_id = ?
            AND (f.dir_id = ? OR f.dir_id IN (
                SELECT id FROM api.drive_directories
                WHERE parent_id = ?
            ))
          GROUP BY f.id, f.file_name, f.dir_id, f.status, rel_path,
                   v.file_size, v.mime_type, v.sha256, v.created_at
          ORDER BY rel_path},
        $root_dir_id, $user_id, $user_id, $root_dir_id, $root_dir_id
    );

    my @result;
    for my $f (@{ $files // [] }) {
        my $raw = delete $f->{pending_tasks};
        $f->{tasks} = ref $raw ? $raw : decode_json($raw // '[]');
        $f->{type}  = 'file';
        $f->{path}  = $prefix . $f->{rel_path};
        delete $f->{rel_path};
        push @result, $f;
    }
    return \@result;
}

sub list_directories {
    my ($self, $email, $parent_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $dirs = $self->{db}->query_rows(
        'SELECT id, dir_name, parent_id, created_at FROM api.drive_directories '
        . 'WHERE user_id = ? AND parent_id IS NOT DISTINCT FROM ? ORDER BY dir_name',
        $user_id, $parent_id
    );

    return { success => 1, directories => $dirs // [] };
}

sub list_all_directories {
    my ($self, $email) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $dirs = $self->{db}->query_rows(
        'SELECT id, dir_name, parent_id, created_at FROM api.drive_directories '
        . 'WHERE user_id = ? ORDER BY dir_name',
        $user_id
    );

    return { success => 1, directories => $dirs // [] };
}

sub copy_file {
    my ($self, $email, $file_id, $dest_dir_id, $dest_file_name) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    # Get source file + current version info
    my $file = $self->{db}->query_row(
        'SELECT f.id, f.file_name, f.current_version_id FROM api.drive_files f WHERE f.id = ? AND f.user_id = ?',
        $file_id, $user_id
    );
    return { error => 'File not found' } unless $file;

    my $version = $self->{db}->query_row(
        'SELECT id, uuid, file_size, mime_type FROM api.drive_versions WHERE id = ?',
        $file->{current_version_id}
    );
    return { error => 'File has no current version' } unless $version;

    # Check quota — fail fast before queuing
    my ($ok, $msg) = $self->_check_quota($user_id, $version->{file_size});
    return { error => $msg } unless $ok;

    # Check for filename conflict at destination
    my $dest_name = $dest_file_name // $file->{file_name};
    my $conflict = $self->{db}->query_row(
        'SELECT id FROM api.drive_files WHERE user_id = ? AND file_name = ? AND dir_id IS NOT DISTINCT FROM ?',
        $user_id, $dest_name, $dest_dir_id
    );
    return { error => "A file named '$dest_name' already exists at the destination" } if $conflict;

    # Enqueue copy task — processor does the actual disk + DB work
    my $task = $self->{db}->query_row(
        'INSERT INTO api.drive_files_tasks (file_id, task, task_data, status_text) VALUES (?, ?, ?, ?) RETURNING id',
        $file_id, 'copy',
        encode_json({
            source_file_id  => $file_id,
            source_version_id => $version->{id},
            source_uuid     => $version->{uuid},
            source_user_id  => $user_id,
            dest_dir_id     => $dest_dir_id,
            dest_file_name  => $dest_name,
            dest_file_size  => $version->{file_size},
            mime_type       => $version->{mime_type},
        }),
        'queued'
    );

    return {
        success  => 1,
        message  => 'Copy queued',
        task_id  => $task->{id},
        file_name => $dest_name,
        dest_dir_id => $dest_dir_id,
    };
}

sub resolve_path {
    my ($self, $email, $path) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    # "/" or "" means root
    my @components = grep { length($_) } split /\//, $path;
    return { dir_id => undef, path => '/' } unless @components;

    my $parent_id = undef;
    my @found;

    for my $name (@components) {
        my $dir = $self->{db}->query_row(
            'SELECT id FROM api.drive_directories WHERE user_id = ? AND dir_name = ? AND parent_id IS NOT DISTINCT FROM ?',
            $user_id, $name, $parent_id
        );
        return { error => 'Directory not found: ' . join('/', @found, $name) } unless $dir;
        push @found, $name;
        $parent_id = $dir->{id};
    }

    return { dir_id => $parent_id, path => join('/', @found) };
}

sub move_file {
    my ($self, $email, $file_id, $dir_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $file = $self->{db}->query_row(
        'SELECT id, file_name FROM api.drive_files WHERE id = ? AND user_id = ?',
        $file_id, $user_id
    );
    return { error => 'File not found' } unless $file;

    # Check for filename conflict at destination
    my $conflict = $self->{db}->query_row(
        'SELECT id FROM api.drive_files WHERE user_id = ? AND file_name = ? AND dir_id IS NOT DISTINCT FROM ? AND id != ?',
        $user_id, $file->{file_name}, $dir_id, $file_id
    );
    return { error => "A file named '$file->{file_name}' already exists at the destination" } if $conflict;

    my $updated = $self->{db}->query_row(
        'UPDATE api.drive_files SET dir_id = ?, updated_at = NOW() WHERE id = ? AND user_id = ? RETURNING id, file_name, dir_id',
        $dir_id, $file_id, $user_id
    );
    return { success => 1, file => $updated };
}

sub create_subdirectory {
    my ($self, $email, $name, $parent_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $dir = $self->{db}->query_row(
        q{INSERT INTO api.drive_directories (user_id, dir_name, parent_id)
          VALUES (?, ?, ?) RETURNING id, dir_name, parent_id},
        $user_id, $name, $parent_id
    );
    return { error => 'Failed to create folder (name may already exist)' } unless $dir;
    return { success => 1, directory => $dir };
}

sub create_directory {
    my ($self, $email, $path) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    # Split path on '/', strip empty components (leading/trailing slashes, doubles)
    my @components = grep { length($_) } split /\//, $path;
    return { error => 'Directory path required' } unless @components;

    my $parent_id = undef;
    my @results;

    for my $name (@components) {
        # Look for existing directory at this level
        my $existing = $self->{db}->query_row(
            'SELECT id, dir_name, parent_id FROM api.drive_directories WHERE user_id = ? AND dir_name = ? AND parent_id IS NOT DISTINCT FROM ?',
            $user_id, $name, $parent_id
        );

        if ($existing) {
            push @results, { id => $existing->{id}, name => $name, parent_id => $parent_id, created => 0 };
            $parent_id = $existing->{id};
        } else {
            my $dir = $self->{db}->query_row(
                'INSERT INTO api.drive_directories (user_id, dir_name, parent_id) VALUES (?, ?, ?) RETURNING id',
                $user_id, $name, $parent_id
            );
            push @results, { id => $dir->{id}, name => $name, parent_id => $parent_id, created => 1 };
            $parent_id = $dir->{id};
        }
    }

    return {
        success     => 1,
        path        => join('/', map { $_->{name} } @results),
        directories => \@results,
        leaf_id     => $results[-1]{id},
    };
}

sub delete_directory {
    my ($self, $email, $dir_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    # Recursively soft-delete ALL files in this dir and ALL descendant dirs
    $self->{db}->query(
        q{WITH RECURSIVE subdirs AS (
            SELECT id FROM api.drive_directories WHERE id = ? AND user_id = ?
            UNION ALL
            SELECT d.id FROM api.drive_directories d JOIN subdirs s ON d.parent_id = s.id
          )
          UPDATE api.drive_files
          SET dir_id = (SELECT id FROM api.drive_directories WHERE user_id = ? AND is_trash = TRUE LIMIT 1),
              deleted_at = NOW(), updated_at = NOW()
          WHERE user_id = ? AND dir_id IN (SELECT id FROM subdirs)},
        $user_id,
        $dir_id, $user_id, $user_id
    );

    # Delete the directory tree (deepest first via order — Postgres handles FK cascade)
    $self->{db}->query(
        q{WITH RECURSIVE subdirs AS (
            SELECT id FROM api.drive_directories WHERE id = ? AND user_id = ?
            UNION ALL
            SELECT d.id FROM api.drive_directories d JOIN subdirs s ON d.parent_id = s.id
          )
          DELETE FROM api.drive_directories WHERE id IN (SELECT id FROM subdirs)},
        $dir_id, $user_id
    );

    return { success => 1 };
}

sub rename_directory {
    my ($self, $email, $dir_id, $new_name) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $dir = $self->{db}->query_row(
        'UPDATE api.drive_directories SET dir_name = ?, updated_at = NOW() WHERE id = ? AND user_id = ? RETURNING id, dir_name, parent_id',
        $new_name, $dir_id, $user_id
    );

    return { error => 'Directory not found' } unless $dir;
    return { success => 1, directory => $dir };
}

sub move_directory {
    my ($self, $email, $dir_id, $new_parent_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    return { error => 'Cannot move a directory into itself' }
        if defined $new_parent_id && $new_parent_id == $dir_id;

    if (defined $new_parent_id) {
        my $parent = $self->{db}->query_row(
            'SELECT id FROM api.drive_directories WHERE id = ? AND user_id = ?',
            $new_parent_id, $user_id
        );
        return { error => 'Target directory not found' } unless $parent;
    }

    my $dir = $self->{db}->query_row(
        'UPDATE api.drive_directories SET parent_id = ?, updated_at = NOW() WHERE id = ? AND user_id = ? RETURNING id, dir_name, parent_id',
        $new_parent_id, $dir_id, $user_id
    );

    return { error => 'Directory not found' } unless $dir;
    return { success => 1, directory => $dir };
}

# Find or create the "Homelab Tasks" root-level directory for this user.
# Returns the directory id.
sub bulk_trash {
    my ($self, $email, $file_ids, $dir_ids, $current_dir_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    # Safety: only trash file IDs that actually live in the stated current directory.
    # This prevents stale IDs from a previous directory view causing accidental deletion
    # of files in a different folder.
    my @safe_ids;
    if (@$file_ids) {
        my $ph   = join(',', ('?') x @$file_ids);
        my $rows = $self->{db}->query_rows(
            qq{SELECT id FROM api.drive_files
               WHERE id IN ($ph) AND user_id = ?
                 AND dir_id IS NOT DISTINCT FROM ?},
            @$file_ids, $user_id, $current_dir_id
        );
        @safe_ids = map { $_->{id} } @{ $rows // [] };
    }

    $self->queue_delete($email, $_) for @safe_ids;
    $self->delete_directory($email, $_) for @$dir_ids;

    return { success => 1, queued => scalar @safe_ids, dirs => scalar @$dir_ids };
}

sub bulk_move {
    my ($self, $email, $file_ids, $dir_ids, $new_dir_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my (@moved, @skipped);

    if (@$file_ids) {
        my $ph = join(',', ('?') x @$file_ids);

        # Classify each selected file: already_there | conflict | ok
        # Uses query_rows (SELECT-only) — never query_rows for writes
        my $rows = $self->{db}->query_rows(
            qq{SELECT f2.id, f2.file_name,
                  CASE
                    WHEN f2.dir_id IS NOT DISTINCT FROM ? THEN 'already_there'
                    WHEN EXISTS (
                        SELECT 1 FROM api.drive_files f3
                        WHERE f3.user_id = f2.user_id
                          AND f3.dir_id IS NOT DISTINCT FROM ?
                          AND f3.file_name = f2.file_name
                          AND f3.id != f2.id
                         
                    ) THEN 'conflict'
                    ELSE 'ok'
                  END AS move_status
               FROM api.drive_files f2
               WHERE f2.id IN ($ph) AND f2.user_id = ?},
            $new_dir_id, $new_dir_id, @$file_ids, $user_id
        );

        my @ok_ids;
        for my $f (@{ $rows // [] }) {
            if ($f->{move_status} eq 'ok') {
                push @ok_ids, $f->{id};
            } elsif ($f->{move_status} eq 'conflict') {
                push @skipped, { id => $f->{id}, name => $f->{file_name}, reason => 'A file with this name already exists in the destination' };
            } else {
                push @skipped, { id => $f->{id}, name => $f->{file_name}, reason => 'Already in this folder' };
            }
        }

        if (@ok_ids) {
            my $ok_ph = join(',', ('?') x @ok_ids);
            # Use query() not query_rows() — query() is used for all writes in Drive.pm
            $self->{db}->query(
                "UPDATE api.drive_files SET dir_id = ?, updated_at = NOW()
                 WHERE id IN ($ok_ph) AND user_id = ?",
                $new_dir_id, @ok_ids, $user_id
            );
            my %name_by_id = map { $_->{id} => $_->{file_name} } @{ $rows // [] };
            @moved = map { { id => $_, name => $name_by_id{$_} } } @ok_ids;
        }
    }

    # Move directories
    for my $dir_id (@$dir_ids) {
        my $row = $self->{db}->query_row(
            'UPDATE api.drive_directories SET parent_id = ?, updated_at = NOW()
             WHERE id = ? AND user_id = ? RETURNING id, dir_name',
            $new_dir_id, $dir_id, $user_id
        );
        push @moved, { id => $row->{id}, name => $row->{dir_name} } if $row;
    }

    return { success => 1, moved => \@moved, skipped => \@skipped };
}

sub find_or_create_tasks_dir {
    my ($self, $user_id) = @_;

    my $existing = $self->{db}->query_row(
        q{SELECT id FROM api.drive_directories
          WHERE user_id = ? AND dir_name = 'Homelab Tasks' AND parent_id IS NULL},
        $user_id
    );
    return $existing->{id} if $existing;

    my $dir = $self->{db}->query_row(
        q{INSERT INTO api.drive_directories (user_id, dir_name, parent_id)
          VALUES (?, 'Homelab Tasks', NULL) RETURNING id},
        $user_id
    );
    return $dir->{id};
}

# Queue a zip task.  Resolves all file paths and builds a complete manifest at
# queue time so the processor needs zero DB queries.  Output lands in dest_dir_id
# (undef = root).  Name is auto-generated as archive_YYYYMMDD_HHMMSS.zip.
sub queue_zip {
    my ($self, $email, $file_ids, $dir_ids, $dest_dir_id) = @_;
    $file_ids //= [];
    $dir_ids  //= [];

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;
    return { error => 'No files or directories specified' }
        unless @$file_ids || @$dir_ids;

    # Auto-generate timestamped name
    my @t = localtime(time);
    my $ts = sprintf('%04d%02d%02d_%02d%02d%02d', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
    my $output_name = "archive_${ts}.zip";

    # Make output_name unique in dest_dir
    my $base_name = $output_name =~ s/\.zip$//ri;
    my $counter = 1;
    while ($self->{db}->query_row(
        q{SELECT id FROM api.drive_files WHERE user_id = ? AND dir_id IS NOT DISTINCT FROM ? AND file_name = ?},
        $user_id, $dest_dir_id, $output_name
    )) {
        $output_name = "$base_name ($counter).zip";
        $counter++;
    }

    # Build manifest: resolve all files with their zip paths, deduplicating names
    my %seen;
    my @items;

    # Flat file_ids → go at root of zip
    if (@$file_ids) {
        my $ph   = join(',', ('?') x @$file_ids);
        my $rows = $self->{db}->query_rows(
            "SELECT f.file_name, v.uuid
             FROM api.drive_files f
             JOIN api.drive_versions v ON v.id = f.current_version_id
             WHERE f.id IN ($ph) AND f.user_id = ?
             ORDER BY f.file_name",
            @$file_ids, $user_id
        );
        for my $r (@{ $rows // [] }) {
            my $zip_path = _unique_zip_name($r->{file_name}, \%seen);
            $seen{$zip_path} = 1;
            push @items, { uuid => $r->{uuid}, zip_path => $zip_path };
        }
    }

    # dir_ids → recursive CTE, preserve subtree structure inside zip
    for my $dir_id (@$dir_ids) {
        my $rows = $self->{db}->query_rows(
            q{WITH RECURSIVE dir_tree AS (
                SELECT id, dir_name AS rel_path
                FROM api.drive_directories WHERE id = ? AND user_id = ?
                UNION ALL
                SELECT d.id, dt.rel_path || '/' || d.dir_name
                FROM api.drive_directories d
                JOIN dir_tree dt ON d.parent_id = dt.id
              )
              SELECT f.file_name, v.uuid, dt.rel_path
              FROM api.drive_files f
              JOIN api.drive_versions v ON v.id = f.current_version_id
              JOIN dir_tree dt ON dt.id = f.dir_id
              WHERE f.user_id = ?
              ORDER BY dt.rel_path, f.file_name},
            $dir_id, $user_id, $user_id
        );
        for my $r (@{ $rows // [] }) {
            my $zip_path = _unique_zip_name($r->{rel_path} . '/' . $r->{file_name}, \%seen);
            $seen{$zip_path} = 1;
            push @items, { uuid => $r->{uuid}, zip_path => $zip_path };
        }
    }

    return { error => 'No files found to zip' } unless @items;

    # Generate output UUID
    my $uuid = do {
        my $rand = '';
        $rand .= sprintf('%08x', int(rand(0xFFFFFFFF))) for 1..4;
        join('-', substr($rand,0,8), substr($rand,8,4),
                  '4' . substr($rand,13,3), substr($rand,16,4), substr($rand,20,12));
    };

    # Create placeholder file + version records
    my $file = $self->{db}->query_row(
        q{INSERT INTO api.drive_files (user_id, file_name, dir_id) VALUES (?, ?, ?) RETURNING id},
        $user_id, $output_name, $dest_dir_id
    );
    my $file_id = $file->{id};

    my $version = $self->{db}->query_row(
        q{INSERT INTO api.drive_versions (file_id, uuid, file_size, mime_type)
          VALUES (?, ?, 0, 'application/zip') RETURNING id},
        $file_id, $uuid
    );

    $self->{db}->query(
        q{UPDATE api.drive_files SET current_version_id = ?, updated_at = NOW() WHERE id = ?},
        $version->{id}, $file_id
    );

    # Enqueue zip task with complete frozen manifest — processor needs no DB queries
    $self->{db}->query(
        q{INSERT INTO api.drive_files_tasks (file_id, task, task_data, status_text) VALUES (?, ?, ?, ?)},
        $file_id, 'zip',
        encode_json({
            user_id           => $user_id + 0,
            output_uuid       => $uuid,
            output_version_id => $version->{id} + 0,
            output_name       => $output_name,
            items             => \@items,
        }),
        'queued'
    );

    return { success => 1, file_id => $file_id };
}

# Compute a unique zip path by appending (1), (2)... before the extension when
# the path is already taken in the %seen hash.
sub _unique_zip_name {
    my ($zip_path, $seen) = @_;
    return $zip_path unless $seen->{$zip_path};
    # Split into: optional dir prefix, base name, optional extension
    my ($prefix, $base, $ext) = $zip_path =~ m{^((?:.+/)?)([^/]+?)(\.[^./]+)?$};
    $prefix //= ''; $ext //= '';
    my $n = 1;
    $n++ while $seen->{"${prefix}${base} ($n)${ext}"};
    return "${prefix}${base} ($n)${ext}";
}

# Queue a delete task instead of directly deleting — processor handles actual removal
sub find_or_create_trash_dir {
    my ($self, $user_id) = @_;
    my $existing = $self->{db}->query_row(
        'SELECT id FROM api.drive_directories WHERE user_id = ? AND is_trash = TRUE LIMIT 1',
        $user_id
    );
    return $existing->{id} if $existing;
    my $dir = $self->{db}->query_row(
        q{INSERT INTO api.drive_directories (user_id, dir_name, parent_id, is_trash)
          VALUES (?, 'Trash', NULL, TRUE) RETURNING id},
        $user_id
    );
    return $dir->{id};
}

# Trash files by moving them to the Trash directory.
# Only trash files that actually live in current_dir_id — prevents stale selections
# from a previous directory view trashing files in a different folder.
sub trash_files {
    my ($self, $email, $file_ids, $current_dir_id) = @_;
    $file_ids //= [];
    return { success => 1, trashed => 0 } unless @$file_ids;

    my $user_id   = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;
    my $trash_id  = $self->find_or_create_trash_dir($user_id);
    my $ph        = join(',', ('?') x @$file_ids);

    $self->{db}->query(
        "UPDATE api.drive_files SET dir_id = ?, deleted_at = NOW(), updated_at = NOW()
         WHERE id IN ($ph) AND user_id = ? AND dir_id IS NOT DISTINCT FROM ?",
        $trash_id, @$file_ids, $user_id, $current_dir_id
    );
    return { success => 1, trash_dir_id => $trash_id };
}

# Restore files from Trash to a destination directory.
sub restore_files {
    my ($self, $email, $file_ids, $dest_dir_id) = @_;
    $file_ids //= [];
    return { success => 1 } unless @$file_ids;

    my $user_id  = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;
    my $trash_id = $self->find_or_create_trash_dir($user_id);
    my $ph       = join(',', ('?') x @$file_ids);

    $self->{db}->query(
        "UPDATE api.drive_files SET dir_id = ?, deleted_at = NULL, updated_at = NOW()
         WHERE id IN ($ph) AND user_id = ? AND dir_id = ?",
        $dest_dir_id, @$file_ids, $user_id, $trash_id
    );
    return { success => 1 };
}

# queue_delete kept for processor backward-compat: now moves to Trash instead of soft-deleting
sub queue_delete {
    my ($self, $email, $file_id) = @_;
    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;
    my $file = $self->{db}->query_row(
        'SELECT dir_id FROM api.drive_files WHERE id = ? AND user_id = ?',
        $file_id, $user_id
    );
    return { error => 'File not found' } unless $file;
    # Skip if already in Trash
    my $trash_id = $self->find_or_create_trash_dir($user_id);
    return { success => 1 } if defined $file->{dir_id} && $file->{dir_id} == $trash_id;
    $self->{db}->query(
        'UPDATE api.drive_files SET dir_id = ?, deleted_at = NOW(), updated_at = NOW() WHERE id = ? AND user_id = ?',
        $trash_id, $file_id, $user_id
    );
    return { success => 1 };
}

sub restore_file {
    my ($self, $email, $file_id) = @_;
    return $self->restore_files($email, [$file_id], undef);  # undef = root
}

sub get_file_meta {
    my ($self, $email, $file_id, $version_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $row;
    if (defined $version_id) {
        $row = $self->{db}->query_row(
            q{SELECT f.id, f.file_name, f.user_id, v.uuid::text AS uuid, v.mime_type
              FROM api.drive_files f
              JOIN api.drive_versions v ON v.file_id = f.id
              WHERE f.id = ? AND f.user_id = ? AND v.id = ? },
            $file_id, $user_id, $version_id
        );
    } else {
        $row = $self->{db}->query_row(
            q{SELECT f.id, f.file_name, f.user_id, v.uuid::text AS uuid, v.mime_type
              FROM api.drive_files f
              JOIN api.drive_versions v ON f.current_version_id = v.id
              WHERE f.id = ? AND f.user_id = ? },
            $file_id, $user_id
        );
    }

    return { error => 'File not found' } unless $row;
    return { success => 1, file => $row };
}

sub list_trash {
    my ($self, $email) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $files = $self->{db}->query_rows(
        q{WITH RECURSIVE dir_path AS (
            SELECT id, dir_name AS path
            FROM api.drive_directories WHERE user_id = ? AND parent_id IS NULL
            UNION ALL
            SELECT d.id, p.path || ' / ' || d.dir_name
            FROM api.drive_directories d JOIN dir_path p ON d.parent_id = p.id
          )
          SELECT f.id, f.file_name, v.file_size, v.mime_type, v.uuid, f.deleted_at,
                 COALESCE('My Drive / ' || dp.path, 'My Drive') AS dir_path
          FROM api.drive_files f
          JOIN api.drive_versions v ON f.current_version_id = v.id
          LEFT JOIN dir_path dp ON f.dir_id = dp.id
          WHERE f.user_id = ? AND f.dir_id IN (SELECT id FROM api.drive_directories WHERE user_id = ? AND is_trash = TRUE)
          ORDER BY f.deleted_at DESC},
        $user_id, $user_id
    );

    return { success => 1, files => $files // [] };
}

sub empty_trash {
    my ($self, $email) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $files = $self->{db}->query_rows(
        'SELECT f.id FROM api.drive_files f WHERE f.user_id = ? AND f.dir_id IN (SELECT id FROM api.drive_directories WHERE user_id = ? AND is_trash = TRUE)',
        $user_id, $user_id
    );

    my $total_bytes = 0;
    my $file_count  = scalar @$files;

    foreach my $file (@$files) {
        my $versions = $self->{db}->query_rows(
            'SELECT uuid, file_size FROM api.drive_versions WHERE file_id = ?',
            $file->{id}
        );
        foreach my $v (@$versions) {
            my $disk_path = $self->_disk_path($user_id, $v->{uuid});
            unlink $disk_path if -f $disk_path;

            # Derivative files (thumbnail, slide_show_image) are never cleaned up
            # otherwise — clean them up here so hard deletes don't leak them.
            my $hex = substr($v->{uuid}, 0, 2) . '/' . substr($v->{uuid}, 2, 2);
            for my $subdir (qw(.thumbnails .slide_show_images)) {
                my $p = "$self->{drive_path}/$subdir/$user_id/$hex/$v->{uuid}.jpg";
                unlink $p if -f $p;
            }

            $total_bytes += $v->{file_size};
        }
    }

    $self->{db}->query(
        'DELETE FROM api.drive_files WHERE user_id = ? AND dir_id IN (SELECT id FROM api.drive_directories WHERE user_id = ? AND is_trash = TRUE)',
        $user_id,
        $user_id
    );

    # Files were on disk until now — this is the moment quota is actually freed.
    $self->_update_quota($user_id, -$total_bytes, -$file_count) if $file_count;

    return { success => 1, deleted_files => $file_count, freed_bytes => $total_bytes };
}

sub list_versions {
    my ($self, $email, $file_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $file = $self->{db}->query_row(
        'SELECT id FROM api.drive_files WHERE id = ? AND user_id = ?',
        $file_id, $user_id
    );
    return { error => 'File not found' } unless $file;

    my $versions = $self->{db}->query_rows(
        'SELECT id, uuid, file_size, mime_type, sha256, created_at FROM api.drive_versions WHERE file_id = ? ORDER BY created_at DESC',
        $file_id
    );

    return { success => 1, versions => $versions // [] };
}

sub get_quota {
    my ($self, $email) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $quota = $self->{db}->query_row(
        'SELECT usage_bytes, file_count FROM api.drive_quota WHERE user_id = ?',
        $user_id
    );
    my $usage_bytes = $quota ? $quota->{usage_bytes} : 0;
    my $file_count  = $quota ? $quota->{file_count}  : 0;

    my $user = $self->{db}->query_row(
        'SELECT quota_mb FROM dovecot.users WHERE id = ?',
        $user_id
    );
    my $limit_bytes = ($user->{quota_mb} // 1024) * 1024 * 1024;

    return {
        success => 1,
        quota => {
            used_bytes   => $usage_bytes,
            limit_bytes  => $limit_bytes,
            file_count   => $file_count,
            percent_used => $limit_bytes > 0 ? int(($usage_bytes / $limit_bytes) * 100) : 0,
        }
    };
}

# Create a share for a file or directory.
# opts: file_id XOR dir_id (required), share_with (email for user share, undef=public), permission
sub create_share {
    my ($self, $email, %opts) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $file_id = $opts{file_id};
    my $dir_id  = $opts{dir_id};
    return { error => 'Specify file_id or dir_id, not both' } if $file_id && $dir_id;
    return { error => 'file_id or dir_id required' } unless $file_id || $dir_id;

    # Verify ownership
    if ($file_id) {
        my $f = $self->{db}->query_row(
            'SELECT id FROM api.drive_files WHERE id = ? AND user_id = ?', $file_id, $user_id);
        return { error => 'File not found' } unless $f;
    } else {
        my $d = $self->{db}->query_row(
            'SELECT id FROM api.drive_directories WHERE id = ? AND user_id = ?', $dir_id, $user_id);
        return { error => 'Directory not found' } unless $d;
    }

    # Resolve share_with email → user_id
    my $shared_with_user_id;
    if (my $sw = $opts{share_with}) {
        my $sw_id = $self->_user_id($sw);
        return { error => "User '$sw' not found on this server" } unless $sw_id;
        return { error => 'Cannot share with yourself' } if $sw_id == $user_id;
        $shared_with_user_id = $sw_id;
    }

    my $token = substr(sha256_hex(rand() . $$ . time()), 0, 64);
    my $permission = $opts{permission} // 'read';

    my $share = $self->{db}->query_row(
        q{INSERT INTO api.drive_shares
            (file_id, dir_id, owner_user_id, shared_with_user_id, share_token, permission)
          VALUES (?, ?, ?, ?, ?, ?)
          RETURNING id, share_token},
        $file_id, $dir_id, $user_id, $shared_with_user_id, $token, $permission
    );

    return { success => 1, share_id => $share->{id}, token => $share->{share_token} };
}

# List all shares created by this user (files and dirs).
sub list_shares {
    my ($self, $email) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $shares = $self->{db}->query_rows(
        q{SELECT s.id, s.file_id, s.dir_id, s.share_token, s.permission,
                 s.is_active, s.created_at, s.access_count,
                 s.shared_with_user_id,
                 CASE WHEN s.file_id IS NOT NULL THEN 'file' ELSE 'dir' END AS share_type,
                 COALESCE(f.file_name, d.dir_name) AS target_name,
                 u.username || '@' || u.domain AS shared_with_email
          FROM api.drive_shares s
          LEFT JOIN api.drive_files       f ON s.file_id = f.id
          LEFT JOIN api.drive_directories d ON s.dir_id  = d.id
          LEFT JOIN users u ON s.shared_with_user_id = u.id
          WHERE s.owner_user_id = ? AND s.is_active = TRUE
          ORDER BY s.created_at DESC},
        $user_id
    );

    return { success => 1, shares => $shares // [] };
}

# List shares that other users have shared with this user.
sub list_shares_with_me {
    my ($self, $email) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $shares = $self->{db}->query_rows(
        q{SELECT s.id, s.file_id, s.dir_id, s.share_token, s.permission,
                 s.created_at, s.access_count,
                 CASE WHEN s.file_id IS NOT NULL THEN 'file' ELSE 'dir' END AS share_type,
                 COALESCE(f.file_name, d.dir_name) AS target_name,
                 v.file_size, v.mime_type,
                 o.username || '@' || o.domain AS owner_email
          FROM api.drive_shares s
          LEFT JOIN api.drive_files       f ON s.file_id = f.id
          LEFT JOIN api.drive_versions    v ON f.current_version_id = v.id
          LEFT JOIN api.drive_directories d ON s.dir_id  = d.id
          JOIN users o ON s.owner_user_id = o.id
          WHERE s.shared_with_user_id = ? AND s.is_active = TRUE
            AND (s.expires_at IS NULL OR s.expires_at > NOW())
          ORDER BY s.created_at DESC},
        $user_id
    );

    return { success => 1, shares => $shares // [] };
}

sub revoke_share {
    my ($self, $email, $share_id) = @_;

    my $user_id = $self->_user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $share = $self->{db}->query_row(
        'UPDATE api.drive_shares SET is_active = FALSE WHERE id = ? AND owner_user_id = ? RETURNING id',
        $share_id, $user_id
    );

    return { error => 'Share not found' } unless $share;
    return { success => 1 };
}

# Validate a share token and return file metadata for download/serving.
# Works for public (no shared_with) and user shares (requester_user_id must match).
sub get_shared_file {
    my ($self, $token, $requester_user_id) = @_;

    my $share = $self->{db}->query_row(
        q{SELECT f.id, f.file_name, f.user_id, v.uuid, v.file_size, v.mime_type, s.id AS share_id,
                 s.shared_with_user_id
          FROM api.drive_shares s
          JOIN api.drive_files f ON s.file_id = f.id
          JOIN api.drive_versions v ON f.current_version_id = v.id
          WHERE s.share_token = ? AND s.is_active = TRUE AND s.file_id IS NOT NULL
            AND (s.expires_at IS NULL OR s.expires_at > NOW())},
        $token
    );

    return { error => 'Share not found or expired' } unless $share;

    # User-to-user share: verify requester is the intended recipient
    if ($share->{shared_with_user_id}) {
        return { error => 'Access denied' }
            unless $requester_user_id && $requester_user_id == $share->{shared_with_user_id};
    }

    $self->{db}->query(
        'UPDATE api.drive_shares SET accessed_at = NOW(), access_count = access_count + 1 WHERE id = ?',
        $share->{share_id}
    );

    return {
        success   => 1,
        user_id   => $share->{user_id},
        uuid      => $share->{uuid},
        file_name => $share->{file_name},
        file_size => $share->{file_size},
        mime_type => $share->{mime_type},
    };
}

# Validate a directory share token and return dir + top-level file list.
sub get_shared_dir {
    my ($self, $token, $requester_user_id) = @_;

    my $share = $self->{db}->query_row(
        q{SELECT s.id AS share_id, s.dir_id, s.shared_with_user_id,
                 d.dir_name, d.user_id AS owner_user_id,
                 o.username || '@' || o.domain AS owner_email
          FROM api.drive_shares s
          JOIN api.drive_directories d ON s.dir_id = d.id
          JOIN users o ON s.owner_user_id = o.id
          WHERE s.share_token = ? AND s.is_active = TRUE AND s.dir_id IS NOT NULL
            AND (s.expires_at IS NULL OR s.expires_at > NOW())},
        $token
    );

    return { error => 'Share not found or expired' } unless $share;

    if ($share->{shared_with_user_id}) {
        return { error => 'Access denied' }
            unless $requester_user_id && $requester_user_id == $share->{shared_with_user_id};
    }

    $self->{db}->query(
        'UPDATE api.drive_shares SET accessed_at = NOW(), access_count = access_count + 1 WHERE id = ?',
        $share->{share_id}
    );

    # Return top-level files in this shared directory
    my $files = $self->{db}->query_rows(
        q{SELECT f.id, f.file_name, v.uuid, v.file_size, v.mime_type, v.sha256,
                 f.user_id AS owner_user_id
          FROM api.drive_files f
          JOIN api.drive_versions v ON v.id = f.current_version_id
          WHERE f.dir_id = ? AND f.user_id = ?
          ORDER BY f.file_name},
        $share->{dir_id}, $share->{owner_user_id}
    );

    return {
        success     => 1,
        dir_id      => $share->{dir_id},
        dir_name    => $share->{dir_name},
        owner_email => $share->{owner_email},
        files       => $files // [],
        token       => $token,
    };
}

1;
