#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Time::HiRes ();
use Cwd qw(abs_path);
use Scalar::Util qw(refaddr);

# Run outside FHEM. All transport functions below are test doubles: this
# process neither reads fhem.cfg nor opens a receiver connection.
# Usage: perl t/pioneeravr-timing.t 70_PIONEERAVR.pm [--baseline]
# Baseline marks known timing defects as TODO; command-content tests must pass.
use vars qw(%defs %attr %modules %data $readingFnAttributes $init_done
            $reread_active);
my ($clock, @writes, @sleeps, @timers);
my @metadata_initializations;

sub simulated_sleep {
    my ($seconds) = @_;
    push @sleeps, $seconds;
    $clock += $seconds;
    return 0;
}

BEGIN {
    # Prevent loading real transport helpers from a local FHEM installation.
    $INC{'SetExtensions.pm'} = __FILE__;
    $INC{'DevIo.pm'} = __FILE__;
    $INC{'FHEM/Meta.pm'} = __FILE__;
    *CORE::GLOBAL::sleep = \&simulated_sleep;
}
{
    no warnings qw(redefine prototype);
    # Also intercept an explicitly imported high-resolution sleep.
    *Time::HiRes::sleep = \&simulated_sleep;
}

sub Log3 { return; }
sub FHEM::Meta::InitMod { push @metadata_initializations, [@_]; return; }
sub fhem { die "Unexpected FHEM command in isolated test\n"; }
sub SetExtensions { die "Unexpected SetExtensions call\n"; }
sub IOWrite {
    my ($hash, @arguments) = @_;
    return PIONEERAVR_Write($hash->{IODev}, @arguments);
}
sub DevIo_CloseDev { delete $_[0]{TCPDev}; return; }
my $open_calls = 0;
my $defer_open = 0;
my $run_open_callback = 0;
my @open_callbacks;
sub DevIo_OpenDev {
    my ($hash, $reopen, $init, $callback) = @_;
    ++$open_calls;
    if ($defer_open && $callback) {
        push @open_callbacks, [$hash, $callback];
        return;
    }
    $hash->{TCPDev} = {};
    $hash->{STATE} = 'opened';
    readingsSingleUpdate($hash, 'state', 'opened');
    # Existing timing tests isolate writes from reconnect initialization.
    if ($callback && $run_open_callback) { $callback->($hash, undef); }
    else { delete $hash->{helper}{opening}; }
    return;
}
sub DevIo_IsOpen { return $_[0]{TCPDev}; }
sub AssignIoPort { return; }
sub setNotifyDev { return; }
sub getKeyValue { return (undef, undef); }
sub escapeLogLine { return $_[0]; }
sub DevIo_SimpleWrite {
    my ($hash, $message) = @_;
    push @writes, [$clock, $message, $hash->{NAME}];
    return;
}
my $disconnect_calls = 0;
sub DevIo_Expect { die "Blocking DevIo_Expect must not be called\n"; }
sub DevIo_Disconnected {
    my ($hash) = @_;
    ++$disconnect_calls;
    DevIo_CloseDev($hash);
    DevIo_setStates($hash, 'disconnected');
    $hash->{CHANGED} = ['DISCONNECTED'];
    PIONEERAVR_Notify($hash, $hash);
}
sub DevIo_TimeoutRead { die "Blocking clear must not run in disable tests\n"; }
sub DevIo_SimpleRead { die "No real receiver input is available\n"; }
sub AttrVal {
    my ($name, $key, $default) = @_;
    return exists $attr{$name}{$key} ? $attr{$name}{$key} : $default;
}
sub ReadingsVal {
    my ($name, $key, $default) = @_;
    return exists $defs{$name}{READINGS}{$key}{VAL}
        ? $defs{$name}{READINGS}{$key}{VAL} : $default;
}
sub readingsBeginUpdate { return; }
sub readingsEndUpdate { return; }
sub readingsSingleUpdate {
    my ($hash, $key, $value) = @_;
    $hash->{READINGS}{$key}{VAL} = $value;
    return;
}
sub readingsBulkUpdate { return readingsSingleUpdate(@_); }
sub DevIo_setStates { $_[0]{STATE} = $_[1]; readingsSingleUpdate($_[0], 'state', $_[1]); }
sub DoTrigger { return; }
sub InternalTimer {
    my ($when, $callback, $argument) = @_;
    push @timers, [$when, $callback, $argument];
    return;
}
sub RemoveInternalTimer {
    my ($argument, $callback) = @_;
    @timers = grep {
        !(refaddr($_->[2]) == refaddr($argument)
          && (!defined($callback) || $_->[1] eq $callback))
    } @timers;
    return;
}

my $module_path = shift @ARGV
    or die "Usage: perl $0 MODULE.pm [--baseline]\n";
my $baseline = @ARGV == 1 && $ARGV[0] eq '--baseline';
die "Unknown arguments\n" if @ARGV && !$baseline;
$module_path = abs_path($module_path)
    or die "Module path does not exist\n";
$clock = 1_000;
$readingFnAttributes = '';
$init_done = 0;
my $loaded = do $module_path;
die "Module load failed: $@ $!\n" unless $loaded;
my $zone_path = $module_path;
$zone_path =~ s/70_PIONEERAVR\.pm\z/71_PIONEERAVRZONE.pm/;
my $zone_loaded = 0;
if (!$baseline && $zone_path ne $module_path && -f $zone_path) {
    my $result = do $zone_path;
    die "Zone module load failed: $@ $!\n" unless $result;
    $zone_loaded = 1;
}
{
    no warnings qw(redefine prototype once);
    # Use deterministic simulated time, without changing the module file.
    *main::gettimeofday = sub { return $clock; };
}

sub new_receiver {
    %defs = (); %attr = (); %modules = (); %data = ();
    @writes = (); @sleeps = (); @timers = ();
    $clock = 1_000;
    my $name = 'test.pioneer';
    my $hash = { NAME => $name, TYPE => 'PIONEERAVR' };
    $defs{$name} = $hash;
    PIONEERAVR_Define($hash, [$name, 'PIONEERAVR', 'telnet',
                             'test.invalid:8102'], {});
    $hash->{READINGS}{presence}{VAL} = 'present';
    $hash->{READINGS}{state}{VAL} = 'opened';
    $hash->{READINGS}{networkStandby}{VAL} = 'on';
    @writes = (); @sleeps = (); @timers = ();
    return $hash;
}

sub commands {
    return [ map { my $message = $_->[1];
                   $message =~ s/\r\n\z//; $message } @writes ];
}

sub drain_send_timers {
    # Advance only scheduled send work. Periodic connection checks are
    # deliberately excluded so the test cannot loop or contact a receiver.
    my $iterations = 0;
    while (1) {
        my @pending = sort { $a->[0] <=> $b->[0] }
            grep { $_->[1] ne 'PIONEERAVR_connectionCheck'
                && $_->[1] ne 'PIONEERAVR_ProbeTimeout' } @timers;
        last unless @pending;
        die "Timer loop exceeded test limit\n" if ++$iterations > 2_000;
        my $next = $pending[0];
        @timers = grep { refaddr($_) != refaddr($next) } @timers;
        $clock = $next->[0] if $next->[0] > $clock;
        my $callback = $next->[1];
        no strict 'refs';
        &{$callback}($next->[2]);
    }
}

sub run_next_send_timer {
    my @pending = sort { $a->[0] <=> $b->[0] }
        grep { $_->[1] eq 'PIONEERAVR_SendNext' } @timers;
    die "No send timer scheduled\n" unless @pending;
    my $next = $pending[0];
    @timers = grep { refaddr($_) != refaddr($next) } @timers;
    $clock = $next->[0] if $next->[0] > $clock;
    PIONEERAVR_SendNext($next->[2]);
}

sub check_async_contract {
    my ($label) = @_;
    my $short_gaps = 0;
    for my $index (1 .. $#writes) {
        ++$short_gaps if $writes[$index][0] - $writes[$index-1][0] < 0.099999;
    }
    diag "$label: writes=" . scalar(@writes) . ", sleep calls="
        . scalar(@sleeps) . ", gaps below 100 ms=$short_gaps";
    TODO: {
        local $TODO = $baseline ? 'Known r31815 timing defects' : undef;
        is(scalar(@sleeps), 0, "$label: no blocking sleep calls");
        is($short_gaps, 0, "$label: at least 100 ms between writes");
    }
}

diag "Testing module: $module_path";
subtest 'Input discovery' => sub {
    my $hash = new_receiver();
    my $started = $clock;
    PIONEERAVR_askForInputNames($hash, 5);
    if (!$baseline) {
        is($clock, $started, 'Input discovery returns without waiting');
        cmp_ok(scalar(@writes), '<=', 1, 'At most one command sent inline');
    }
    drain_send_timers();
    my @expected;
    for my $input (0 .. 59) {
        push @expected, sprintf('?RGB%02d', $input);
        push @expected, map { sprintf('?SSC%02d%02d', $input, $_) } 0 .. 3;
        push @expected, sprintf('?ILA%02d', $input);
    }
    is(scalar(@writes), 360, 'Six requests for each of 60 inputs');
    is_deeply(commands(), \@expected, 'Complete input-discovery order preserved');
    check_async_contract('Input discovery');
};

subtest 'Full status request' => sub {
    my $hash = new_receiver();
    my @status = map { values %$_ } values %{$hash->{helper}{GETS}};
    my $started = $clock;
    PIONEERAVR_statusUpdate($hash);
    is($clock, $started, 'Full status returns without waiting') if !$baseline;
    drain_send_timers();
    my @actual = @{commands()};
    is(scalar(@actual), scalar(@status) + 360, 'Status and input requests present');
    my @received_status = splice @actual, 0, scalar(@status);
    is_deeply([sort @received_status], [sort @status],
              'All zones queried, independent of hash iteration order');
    is($actual[0], '?RGB00', 'Input discovery follows status requests');
    is($actual[-1], '?ILA59', 'Last input-level request preserved');
    check_async_contract('Full status');
};

subtest 'Power-on sequence' => sub {
    my $hash = new_receiver();
    my $started = $clock;
    my $error = PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {});
    is($clock, $started, 'Power-on returns without waiting') if !$baseline;
    drain_send_timers();
    ok(!defined($error), 'Power-on accepted with network standby on');
    is_deeply(commands(), ['', '', "\n\rPO", "\n\rPO"],
              'Existing wake-up and repeated power-on sequence preserved');
    cmp_ok($writes[3][0] - $writes[2][0], '>=', 0.199999,
           'At least 200 ms between power-on attempts') if !$baseline;
    check_async_contract('Power on');
};

if (!$baseline) {
    subtest 'Interactive command preempts background discovery' => sub {
        my $hash = new_receiver();
        PIONEERAVR_askForInputNames($hash, 5);
        PIONEERAVR_Write($hash, 'MO');
        run_next_send_timer();
        is(commands()->[1], 'MO', 'Mute sent in next free time slot');
        drain_send_timers();
        is(scalar(@writes), 361, 'Control plus complete scan retained');
        is(commands()->[-1], '?ILA59', 'Background scan completes');
        check_async_contract('Interactive command during discovery');
    };

    subtest 'Overlapping scan requests are coalesced' => sub {
        my $hash = new_receiver();
        PIONEERAVR_statusUpdate($hash);
        PIONEERAVR_statusUpdate($hash);
        PIONEERAVR_askForInputNames($hash, 5);
        drain_send_timers();
        is(scalar(@writes), 406, 'Repeated requests do not duplicate queued scans');
    };

    subtest 'Late timer does not cause catch-up bursts' => sub {
        my $hash = new_receiver();
        PIONEERAVR_Write($hash, 'MO');
        PIONEERAVR_Write($hash, '?M');
        PIONEERAVR_Write($hash, '?P');
        $clock += 5;
        drain_send_timers();
        is_deeply(commands(), ['MO', '?M', '?P'], 'FIFO order preserved');
        cmp_ok($writes[2][0] - $writes[1][0], '>=', 0.099999,
               'Next deadline based on actual send time');
    };

    subtest 'Early callback cannot violate send deadline' => sub {
        my $hash = new_receiver();
        PIONEERAVR_Write($hash, 'MO');
        PIONEERAVR_Write($hash, '?M');
        PIONEERAVR_SendNext($hash);
        is(scalar(@writes), 1, 'Nothing sent before deadline');
        is(scalar(grep { $_->[1] eq 'PIONEERAVR_SendNext' } @timers), 1,
           'Exactly one replacement send timer');
        drain_send_timers();
        is(scalar(@writes), 2, 'Deferred command eventually sent once');
    };

    subtest 'Closed transport cancels pending commands' => sub {
        my $hash = new_receiver();
        PIONEERAVR_askForInputNames($hash, 5);
        PIONEERAVR_Write($hash, 'MO');
        DevIo_CloseDev($hash);
        drain_send_timers();
        is(scalar(@writes), 1, 'No command sent after disconnect');
        ok(!exists $hash->{helper}{sendQueue}, 'Queue released');
    };

    subtest 'Transport replacement cannot replay old commands' => sub {
        my $hash = new_receiver();
        PIONEERAVR_Write($hash, '?P');
        PIONEERAVR_Write($hash, 'MO');
        $hash->{TCPDev} = {};
        drain_send_timers();
        is_deeply(commands(), ['?P'], 'Old mute not sent on replacement socket');
        PIONEERAVR_Write($hash, '?V');
        is_deeply(commands(), ['?P', '?V'], 'New command accepted on new socket');
    };

    subtest 'New command detects replaced transport before old callback' => sub {
        my $hash = new_receiver();
        PIONEERAVR_Write($hash, '?P');
        PIONEERAVR_Write($hash, 'MO');
        $hash->{TCPDev} = {};
        PIONEERAVR_Write($hash, '?V');
        drain_send_timers();
        is_deeply(commands(), ['?P', '?V'], 'Only fresh command retained');
    };

    subtest 'Manual reopen discards pending work' => sub {
        my $hash = new_receiver();
        PIONEERAVR_askForInputNames($hash, 5);
        PIONEERAVR_Write($hash, 'MO');
        PIONEERAVR_Reopen($hash);
        drain_send_timers();
        is(scalar(@writes), 1, 'No stale scan or mute replayed after reopen');
        ok(!exists $hash->{helper}{sendQueue}, 'Reopen resets queue');
    };

    subtest 'Power-supply shutdown clears work and timer' => sub {
        my $hash = new_receiver();
        $hash->{helper}{powerSupplyDevice} = 'test.power:state';
        $defs{'test.power'}{READINGS}{state}{VAL} = 'off';
        PIONEERAVR_askForInputNames($hash, 5);
        is(scalar(@writes), 0, 'No request accepted while supply is off');
        $defs{'test.power'}{READINGS}{state}{VAL} = 'on';
        PIONEERAVR_askForInputNames($hash, 5);
        $defs{'test.power'}{READINGS}{state}{VAL} = 'off';
        PIONEERAVR_PowerSupplyChanged($hash);
        drain_send_timers();
        is(scalar(@writes), 1, 'No writes after shutdown');
        ok(!DevIo_IsOpen($hash), 'Transport closed');
        ok(!exists $hash->{helper}{sendQueue}, 'Pending work released');
    };

    subtest 'Undef and stale callback do not send commands' => sub {
        my $hash = new_receiver();
        PIONEERAVR_askForInputNames($hash, 5);
        PIONEERAVR_Undef($hash, '');
        delete $defs{$hash->{NAME}};
        PIONEERAVR_SendNext($hash);
        drain_send_timers();
        is(scalar(@writes), 1, 'No sends after undef');
        ok(!exists $hash->{helper}{sendQueue}, 'Queue released on undef');
    };

    subtest 'Deleted device is protected even without undef callback' => sub {
        my $hash = new_receiver();
        PIONEERAVR_Write($hash, '?P');
        PIONEERAVR_Write($hash, 'MO');
        delete $defs{$hash->{NAME}};
        drain_send_timers();
        is(scalar(@writes), 1, 'Stale callback cannot control deleted device');
    };

    subtest 'Connection check respects scheduler' => sub {
        my $hash = new_receiver();
        PIONEERAVR_askForInputNames($hash, 5);
        PIONEERAVR_connectionCheck($hash);
        ok(!exists $hash->{helper}{connectionProbe}, 'Probe deferred while scan is active');
        drain_send_timers();
        PIONEERAVR_connectionCheck($hash);
        ok(!exists $hash->{helper}{connectionProbe}, 'Probe deferred during final quiet interval');
        $clock += 0.2;
        PIONEERAVR_connectionCheck($hash);
        ok(exists $hash->{helper}{connectionProbe}, 'Probe runs after quiet interval');
        my $after_probe = scalar(@writes);
        PIONEERAVR_Write($hash, '?V');
        is(scalar(@writes), $after_probe, 'New command waits after probe');
        drain_send_timers();
        is(scalar(@writes), $after_probe + 1, 'Command eventually sent');
    };

    subtest 'Disconnect notification cancels scans' => sub {
        my $hash = new_receiver();
        PIONEERAVR_askForInputNames($hash, 5);
        PIONEERAVR_Write($hash, 'MO');
        $hash->{CHANGED} = ['DISCONNECTED'];
        PIONEERAVR_Notify($hash, $hash);
        drain_send_timers();
        is(scalar(@writes), 1, 'Notification stops all pending commands');
        ok(!exists $hash->{helper}{sendQueue}, 'No orphan queue');
        is(ReadingsVal($hash->{NAME}, 'presence', ''), 'absent',
           'Existing absent-state handling preserved');
    };

    subtest 'Reconnect cancels asynchronous probe deadline' => sub {
        my $hash = new_receiver();
        PIONEERAVR_connectionCheck($hash);
        PIONEERAVR_Reopen($hash);
        ok(!exists $hash->{helper}{connectionProbe}, 'Reopen cancels probe');
        $hash->{CHANGED} = ['CONNECTED'];
        PIONEERAVR_Notify($hash, $hash);
        drain_send_timers();
        is_deeply(commands(), ['', '?P', '?M', '?V', '?F'],
                  'Reconnect sends fresh paced requests');
    };

    subtest 'Receiver queues and cleanup are independent' => sub {
        my $first = new_receiver();
        my $second = { NAME => 'test.second', TYPE => 'PIONEERAVR' };
        $defs{'test.second'} = $second;
        PIONEERAVR_Define($second,
            ['test.second', 'PIONEERAVR', 'telnet', 'second.invalid:8102'], {});
        PIONEERAVR_Write($first, 'MO');
        PIONEERAVR_Write($first, '?M');
        PIONEERAVR_Write($second, 'MF');
        PIONEERAVR_Write($second, '?P');
        is(scalar(@writes), 2, 'Each receiver can send its first command immediately');
        PIONEERAVR_ClearSendQueue($first);
        drain_send_timers();
        is_deeply(commands(), ['MO', 'MF', '?P'],
                  'Clearing first receiver does not cancel second receiver timer');
        is($writes[-1][2], 'test.second', 'Remaining command goes to second receiver');
    };

    subtest 'Reconnect probes are separate paced commands' => sub {
        my $hash = new_receiver();
        $hash->{CHANGED} = ['CONNECTED'];
        PIONEERAVR_Notify($hash, $hash);
        is(scalar(@writes), 1, 'Only first probe sent inline');
        drain_send_timers();
        is_deeply(commands(), ['?P', '?M', '?V', '?F'],
                  'All original reconnect probes retained');
        check_async_contract('Reconnect probes');
    };

    subtest 'Zone power-on shares parent pacing' => sub {
        plan skip_all => 'Place 71_PIONEERAVRZONE.pm beside parent module'
            unless $zone_loaded;
        for my $zone (['zone2', 'APO'], ['zone3', 'BPO'], ['hdZone', 'ZEO']) {
            my $hash = new_receiver();
            my $zone_hash = {
                NAME => 'test.zone', TYPE => 'PIONEERAVRZONE', IODev => $hash,
                helper => { ZONE => $zone->[0] },
            };
            $defs{'test.zone'} = $zone_hash;
            PIONEERAVR_askForInputNames($hash, 5);
            my $started = $clock;
            PIONEERAVRZONE_Set($zone_hash, 'test.zone', 'on');
            is($clock, $started, "$zone->[0]: returns without waiting");
            drain_send_timers();
            is_deeply([@{commands()}[0 .. 2]], ['?RGB00', '', $zone->[1]],
                      "$zone->[0]: wake-up and power-on take priority");
            is(scalar(@writes), 362, "$zone->[0]: full scan still completes");
            check_async_contract($zone->[0]);
        }
    };
}

# Parser regression coverage uses complete and fragmented receiver replies.
sub setKeyValue { return; }
sub Dispatch { die "Unexpected zone dispatch in main-zone parser test\n"; }
sub feed_receiver {
    my ($hash, $chunk) = @_;
    no warnings qw(redefine once);
    local *main::DevIo_SimpleRead = sub { return $chunk; };
    PIONEERAVR_Read($hash);
}

subtest 'Parser: Sonos and SonosA remain separate inputs' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "RGB011SonosA\r\nRGB151Sonos\r\nFN15\r\n");
    is($hash->{helper}{INPUTNAMES}{'01'}{aliasName}, 'sonosa', 'SonosA normalized separately');
    is($hash->{helper}{INPUTNAMES}{'15'}{aliasName}, 'sonos', 'Sonos normalized separately');
    is(ReadingsVal($hash->{NAME}, 'input', ''), 'sonos', 'FN15 selects Sonos');
};

subtest 'Parser: skip state follows input-specific replies' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "SSC010301\r\nSSC150300\r\n");
    is($hash->{helper}{INPUTNAMES}{'01'}{enabled}, 0, 'input 01 skipped');
    is($hash->{helper}{INPUTNAMES}{'15'}{enabled}, 1, 'input 15 enabled');
};

subtest 'Parser: volume readings use Pioneer scale' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "VOL128\r\n");
    is(ReadingsVal($hash->{NAME}, 'volumeStraight', ''), -16.5, 'raw 128 is -16.5 dB');
    is(ReadingsVal($hash->{NAME}, 'volume', ''), 69, 'percentage rounded');
};

subtest 'Parser: display hex decodes to readable text' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "FL004D2E564F4C20202D31362E356442\r\n");
    like(ReadingsVal($hash->{NAME}, 'display', ''), qr/M\.VOL.*-16\.5dB/, 'volume display decoded');
};

subtest 'Parser: fragmented response stays buffered until complete' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, 'VOL1');
    is($hash->{PARTIAL}, 'VOL1', 'incomplete line retained');
    feed_receiver($hash, "28\r\n");
    is(ReadingsVal($hash->{NAME}, 'volumeStraight', ''), -16.5, 'fragmented reply decoded');
};

subtest 'Parser: combined replies are all consumed' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "PWR0\r\nMUT1\r\nVOL128\r\n");
    is(ReadingsVal($hash->{NAME}, 'power', ''), 'on', 'power parsed');
    is(ReadingsVal($hash->{NAME}, 'mute', ''), 'off', 'mute parsed');
    is($hash->{PARTIAL}, '', 'all complete lines consumed');
};

# Input-alias commands: argument handling, wire format and read-back.
subtest 'Rename: spaces, pacing and confirmed alias' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "RGB151Sonos\r\n");
    my $result = PIONEERAVR_Set($hash,
        [$hash->{NAME}, 'renameInputAlias', 'sonos', 'PIONEER', 'GT'], {});
    is($result, undef, 'rename accepted');
    is($hash->{helper}{INPUTNAMES}{'15'}{aliasName}, 'sonos',
       'alias is not changed before receiver confirms it');
    drain_send_timers();
    is_deeply(commands(), ['PIONEER GT1RGB15', '?RGB15'],
              'full name and targeted read-back sent in order');
    check_async_contract('rename');
    feed_receiver($hash, "RGB151PIONEER GT\r\n");
    is($hash->{helper}{INPUTNAMES}{'15'}{aliasName}, 'pioneerGt',
       'confirmed alias uses existing normalization');
};

subtest 'Rename: invalid names cause no writes' => sub {
    for my $args ([], ['sonos'], ['sonos', ''], ['sonos', '   '],
                  ['sonos', '123456789012345'], ['sonos', "A\r\nPF"],
                  ['sonos', "A\tB"], ['sonos', chr(0xe4)]) {
        my $hash = new_receiver();
        feed_receiver($hash, "RGB151Sonos\r\n");
        my $result = PIONEERAVR_Set($hash,
            [$hash->{NAME}, 'renameInputAlias', @$args], {});
        ok(defined($result) && length($result), 'invalid arguments rejected');
        drain_send_timers();
        is(scalar @writes, 0, 'no rename or query sent');
    }
};

subtest 'Rename: boundaries and default input name' => sub {
    for my $alias ('0', '12345678901234') {
        my $hash = new_receiver();
        my $result = PIONEERAVR_Set($hash,
            [$hash->{NAME}, 'renameInputAlias', 'cd', $alias], {});
        is($result, undef, 'valid boundary accepted using default name');
        drain_send_timers();
        is_deeply(commands(), [$alias . '1RGB01', '?RGB01'],
                  'default CD resolves to input 01');
    }
};

subtest 'Rename: unknown and ambiguous selectors are rejected' => sub {
    my $hash = new_receiver();
    my $result = PIONEERAVR_Set($hash,
        [$hash->{NAME}, 'renameInputAlias', 'missingInput', 'Test'], {});
    like($result, qr/Unknown input name/, 'unknown input rejected');
    feed_receiver($hash, "RGB011Same\r\nRGB151Same\r\n");
    $result = PIONEERAVR_Set($hash,
        [$hash->{NAME}, 'renameInputAlias', 'same', 'Test'], {});
    like($result, qr/Ambiguous input name/, 'duplicate alias rejected');
    drain_send_timers();
    is(scalar @writes, 0, 'neither case causes a write');
};

# Async connection checks: real module state transitions, simulated transport.
subtest 'Async probe: R reply cancels deadline and rearms idle check' => sub {
    my $hash = new_receiver();
    my $started = $clock;
    PIONEERAVR_connectionCheck($hash);
    is($clock, $started, 'check returns without waiting');
    is_deeply(commands(), [''], 'established CR/LF probe sent');
    my $deadline = $hash->{helper}{connectionProbe}{deadline};
    is($deadline, $started + 5, 'timeout starts at actual send');
    $clock += 0.05;
    feed_receiver($hash, "R\r\n");
    ok(!exists $hash->{helper}{connectionProbe}, 'reply completes probe');
    is(scalar(grep { $_->[1] eq 'PIONEERAVR_ProbeTimeout' } @timers), 0,
       'deadline timer removed');
    is($hash->{helper}{nextConnectionCheck}, $clock + 60,
       'idle check scheduled from reply');
    $clock = $deadline + 1;
    PIONEERAVR_ProbeTimeout($hash);
    ok(DevIo_IsOpen($hash), 'stale timeout after reply does not disconnect');
};

subtest 'Async probe: fragments cannot postpone timeout' => sub {
    my $hash = new_receiver();
    PIONEERAVR_connectionCheck($hash);
    my $deadline = $hash->{helper}{connectionProbe}{deadline};
    $clock += 1;
    feed_receiver($hash, 'R');
    is($hash->{helper}{connectionProbe}{deadline}, $deadline,
       'partial reply does not extend deadline');
    $clock = $deadline - 0.01;
    PIONEERAVR_ProbeTimeout($hash);
    ok(DevIo_IsOpen($hash), 'early callback does not disconnect');
    $clock = $deadline;
    PIONEERAVR_ProbeTimeout($hash);
    ok(!DevIo_IsOpen($hash), 'missing complete reply disconnects via DevIo');
    is(ReadingsVal($hash->{NAME}, 'presence', ''), 'absent', 'presence is absent');
    ok(!exists $hash->{helper}{sendQueue}, 'pending sends discarded');
};

subtest 'Async probe: normal reply is processed and confirms liveness' => sub {
    my $hash = new_receiver();
    PIONEERAVR_connectionCheck($hash);
    feed_receiver($hash, "VOL128\r\n");
    ok(!exists $hash->{helper}{connectionProbe}, 'normal reply completes check');
    is(ReadingsVal($hash->{NAME}, 'volumeStraight', ''), -16.5,
       'reply processed through normal parser');
};

subtest 'Async probe: controls retain pacing while awaiting response' => sub {
    my $hash = new_receiver();
    PIONEERAVR_connectionCheck($hash);
    PIONEERAVR_Write($hash, '?V');
    is(scalar @writes, 1, 'control waits for probe quiet interval');
    drain_send_timers();
    is_deeply(commands(), ['', '?V'], 'control does not wait for reply timeout');
    check_async_contract('async probe and control');
    feed_receiver($hash, "VOL128\r\n");
    ok(!exists $hash->{helper}{connectionProbe}, 'response cancels original deadline');
};

subtest 'Async probe: replacement socket and removed device are protected' => sub {
    for my $mode ('socket', 'deleted', 'reopen', 'powerOff', 'disconnect') {
        my $hash = new_receiver();
        PIONEERAVR_connectionCheck($hash);
        my $deadline = $hash->{helper}{connectionProbe}{deadline};
        if ($mode eq 'socket') { $hash->{TCPDev} = {}; }
        elsif ($mode eq 'deleted') { delete $defs{$hash->{NAME}}; }
        elsif ($mode eq 'reopen') { PIONEERAVR_Reopen($hash); }
        elsif ($mode eq 'disconnect') {
            $hash->{CHANGED} = ['DISCONNECTED'];
            PIONEERAVR_Notify($hash, $hash);
        }
        else {
            $hash->{helper}{powerSupplyDevice} = 'test.power:state';
            $defs{'test.power'}{READINGS}{state}{VAL} = 'off';
        }
        my $before = $disconnect_calls;
        $clock = $deadline + 1;
        PIONEERAVR_ProbeTimeout($hash);
        is($disconnect_calls, $before, "$mode: stale probe does not disconnect");
        ok(!exists $hash->{helper}{connectionProbe}, "$mode: probe released");
    }
};

subtest 'Async probe: duplicate checks and per-receiver state' => sub {
    my $first = new_receiver();
    PIONEERAVR_connectionCheck($first);
    PIONEERAVR_connectionCheck($first);
    is(scalar @writes, 1, 'duplicate check sends no second probe');
    my $second = { NAME => 'test.second', TYPE => 'PIONEERAVR' };
    $defs{'test.second'} = $second;
    PIONEERAVR_Define($second,
        ['test.second', 'PIONEERAVR', 'telnet', 'second.invalid:8000'], {});
    PIONEERAVR_connectionCheck($second);
    feed_receiver($first, "R\r\n");
    ok(!exists $first->{helper}{connectionProbe}, 'first probe completed');
    ok(exists $second->{helper}{connectionProbe}, 'second probe still pending');
    $clock = $second->{helper}{connectionProbe}{deadline};
    PIONEERAVR_ProbeTimeout($second);
    ok(DevIo_IsOpen($first), 'second timeout does not affect first receiver');
};

subtest 'Async probe: off disables periodic checks but not sent-command check' => sub {
    my $hash = new_receiver();
    $attr{$hash->{NAME}}{connectionCheck} = 'off';
    PIONEERAVR_Write($hash, '?V');
    ok(exists $hash->{helper}{nextConnectionCheck}, 'write still schedules timeout check');
    feed_receiver($hash, "VOL128\r\n");
    ok(!exists $hash->{helper}{nextConnectionCheck}, 'reply leaves periodic check disabled');
    PIONEERAVR_connectionCheck($hash);
    drain_send_timers();
    # It may defer for the previous command's quiet interval; retry at idle.
    $clock += 5;
    PIONEERAVR_connectionCheck($hash);
    feed_receiver($hash, "R\r\n");
    ok(!exists $hash->{helper}{connectionProbe}, 'probe reply processed with periodic checks off');
    is(scalar(grep { $_->[1] eq 'PIONEERAVR_connectionCheck' } @timers), 0,
       'no periodic timer remains');
};

subtest 'Async probe: undefined read preserves existing partial buffer' => sub {
    my $hash = new_receiver();
    $hash->{PARTIAL} = 'VOL1';
    {
        no warnings qw(redefine once);
        local *main::DevIo_SimpleRead = sub { return undef; };
        PIONEERAVR_Read($hash);
    }
    is($hash->{PARTIAL}, 'VOL1', 'undefined read is not concatenated or parsed');
};

subtest 'Async probe: timeout reconnects through existing ReadyFn' => sub {
    my $hash = new_receiver();
    PIONEERAVR_connectionCheck($hash);
    $clock = $hash->{helper}{connectionProbe}{deadline};
    PIONEERAVR_ProbeTimeout($hash);
    is(ReadingsVal($hash->{NAME}, 'state', ''), 'disconnected',
       'DevIo disconnected state retained');
    ok(!DevIo_IsOpen($hash), 'timeout does not open a socket inline');
    PIONEERAVR_Ready($hash);
    ok(DevIo_IsOpen($hash), 'existing ReadyFn invokes DevIo open');
};

subtest 'Async probe: undef removes the deadline timer' => sub {
    my $hash = new_receiver();
    PIONEERAVR_connectionCheck($hash);
    PIONEERAVR_Undef($hash, '');
    ok(!exists $hash->{helper}{connectionProbe}, 'probe state released');
    is(scalar(grep { $_->[1] eq 'PIONEERAVR_ProbeTimeout' } @timers), 0,
       'no orphan deadline timer');
};

# Model FHEM's real ordering: AttrFn first, attribute storage second.
sub change_disable {
    my ($hash, $value) = @_;
    my $name = $hash->{NAME};
    my $cmd = defined($value) ? 'set' : 'del';
    my $result = PIONEERAVR_Attr($cmd, $name, 'disable', $value);
    if (!defined($result)) {
        if (defined $value) { $attr{$name}{disable} = $value; }
        else { delete $attr{$name}{disable}; }
    }
    return $result;
}

subtest 'Disable: validation leaves transport and state intact' => sub {
    my $hash = new_receiver();
    for my $value ('2', '-1', 'yes', '') {
        like(change_disable($hash, $value), qr/disable must be 0 or 1/,
             'invalid disable value rejected');
        ok(DevIo_IsOpen($hash), 'invalid value does not close transport');
    }
};

subtest 'Disable: stop probe and keep last known receiver power' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "PWR0\r\nVOL128\r\n");
    PIONEERAVR_connectionCheck($hash);
    $clock += 0.2;
    PIONEERAVR_connectionCheck($hash);
    ok($hash->{helper}{connectionProbe}, 'probe is active');
    my $before = scalar @writes;
    is(change_disable($hash, 1), undef, 'disable accepted');
    ok(!DevIo_IsOpen($hash), 'connection closed');
    ok(!exists $hash->{helper}{connectionProbe}, 'probe removed');
    ok(!exists $hash->{helper}{sendQueue}, 'queue removed');
    is(scalar @timers, 0, 'all device timers removed');
    is(ReadingsVal($hash->{NAME}, 'stateAV', ''), 'disabled', 'stateAV explains pause');
    is(ReadingsVal($hash->{NAME}, 'power', ''), 'on', 'receiver power remains on');
    is(ReadingsVal($hash->{NAME}, 'volumeStraight', ''), -16.5, 'volume retained');
    is(scalar @writes, $before, 'disable sends no power command');
};

subtest 'Disable: active scan and queued controls are discarded' => sub {
    my $hash = new_receiver();
    PIONEERAVR_askForInputNames($hash, 5);
    PIONEERAVR_Write($hash, 'MO');
    my $before = scalar @writes;
    change_disable($hash, 1);
    drain_send_timers();
    PIONEERAVR_SendNext($hash);
    is(scalar @writes, $before, 'no queued writes after disabling');
};

subtest 'Disable: main controls fail explicitly and cached gets work' => sub {
    my $hash = new_receiver();
    $hash->{READINGS}{volumeStraight}{VAL} = -16.5;
    change_disable($hash, 1);
    for my $args (['on'], ['off'], ['reopen'], ['statusRequest'],
                  ['raw', '?V'], ['input', 'cd']) {
        like(PIONEERAVR_Set($hash, [$hash->{NAME}, @$args], {}), qr/disabled/,
             'control rejected');
    }
    is(PIONEERAVR_Get($hash, [$hash->{NAME}, 'volumeStraight'], {}), -16.5,
       'cached reading still available');
    like(PIONEERAVR_Get($hash, [$hash->{NAME}, 'loadInputNames'], {}), qr/disabled/,
         'fresh query rejected');
    is(scalar @writes, 0, 'no controls sent');
};

subtest 'Disable: all zone controls use parent disabled state' => sub {
    my $hash = new_receiver();
    change_disable($hash, 1);
    for my $zone ('zone2', 'zone3', 'hdZone') {
        my $child = {NAME => 'test.zone', TYPE => 'PIONEERAVRZONE',
                     IODev => $hash, helper => {ZONE => $zone}};
        $defs{'test.zone'} = $child;
        like(PIONEERAVRZONE_Set($child, 'test.zone', 'on'), qr/disabled/,
             "$zone: on rejected");
        like(PIONEERAVRZONE_Set($child, 'test.zone', 'statusRequest'), qr/disabled/,
             "$zone: status request rejected");
        like(PIONEERAVRZONE_Get($child, 'test.zone', 'power'), qr/disabled/,
             "$zone: uncached get rejected");
    }
    is(scalar @writes, 0, 'no zone traffic');
};

subtest 'Disable: direct callbacks cannot restart communication' => sub {
    my $hash = new_receiver();
    change_disable($hash, 1);
    my $before = $open_calls;
    PIONEERAVR_Ready($hash);
    PIONEERAVR_OpenDev($hash, 1, 1);
    PIONEERAVR_Reopen($hash);
    PIONEERAVR_AfterOpen($hash, 1);
    PIONEERAVR_connectionCheck($hash);
    PIONEERAVR_ProbeTimeout($hash);
    PIONEERAVR_screenUpdate($hash);
    PIONEERAVR_Clear($hash);
    PIONEERAVR_Read($hash);
    PIONEERAVR_Write($hash, '?P');
    PIONEERAVR_QueueBackground($hash, 'test', ['?P']);
    is($open_calls, $before, 'no reconnect while disabled');
    is(scalar @writes, 0, 'no writes while disabled');
    is(scalar @timers, 0, 'no timers restarted');
};

subtest 'Disable: enabling defers reconnect until attribute is stored' => sub {
    for my $value (0, undef) {
        my $hash = new_receiver();
        change_disable($hash, 1);
        my $before = $open_calls;
        change_disable($hash, $value);
        is($open_calls, $before, 'AttrFn does not connect inline');
        drain_send_timers();
        is($open_calls, $before + 1, 'zero/deletion reconnects once');
        ok(DevIo_IsOpen($hash), 'transport restored');
        ok(!PIONEERAVR_IsDisabled($hash), 'effective disabled flag cleared');
    }
};

subtest 'Disable: re-enable does not replay stale scan or mute' => sub {
    my $hash = new_receiver();
    PIONEERAVR_askForInputNames($hash, 5);
    PIONEERAVR_Write($hash, 'MO');
    change_disable($hash, 1);
    change_disable($hash, 0);
    drain_send_timers();
    is_deeply(commands(), ['?RGB00'], 'old scan and mute were discarded');
};

subtest 'Disable: external supply off prevents re-enable reconnect' => sub {
    my $hash = new_receiver();
    $attr{$hash->{NAME}}{powerSupplyDevice} = 'test.power:state';
    $defs{'test.power'}{READINGS}{state}{VAL} = 'off';
    $hash->{helper}{powerSupplyState} = 'on';
    change_disable($hash, 1);
    my $before = $open_calls;
    change_disable($hash, 0);
    drain_send_timers();
    is($open_calls, $before, 'no reconnect with supply off');
    ok(!DevIo_IsOpen($hash), 'transport remains closed');
    is($hash->{helper}{powerSupplyState}, 'off', 'missed supply event synchronized');
    $defs{'test.power'}{READINGS}{state}{VAL} = 'on';
    PIONEERAVR_PowerSupplyChanged($hash);
    is($open_calls, $before + 1, 'subsequent supply-on opens connection');
};

subtest 'Disable: define with stored attribute never opens a transport' => sub {
    for my $protocol ('telnet', 'serial') {
        my $hash = new_receiver();
        change_disable($hash, 1);
        my $before = $open_calls;
        PIONEERAVR_Define($hash, [$hash->{NAME}, 'PIONEERAVR', $protocol,
            $protocol eq 'telnet' ? 'test.invalid:8000' : '/dev/test'], {});
        is($open_calls, $before, "$protocol: no open during redefine");
        ok($hash->{helper}{INPUTNAMES}, "$protocol: helper tables initialized");
        is(ReadingsVal($hash->{NAME}, 'state', ''), 'disabled', "$protocol: disabled state");
    }
};

subtest 'Disable: late CONNECTED notification closes transport without queries' => sub {
    my $hash = new_receiver();
    change_disable($hash, 1);
    $hash->{TCPDev} = {};
    $hash->{CHANGED} = ['CONNECTED'];
    PIONEERAVR_Notify($hash, $hash);
    ok(!DevIo_IsOpen($hash), 'late socket closed');
    is(scalar @writes, 0, 'no reconnect queries');
};

subtest 'Disable: pending async connect closes on late completion' => sub {
    my $hash = new_receiver();
    $defer_open = 1;
    PIONEERAVR_Reopen($hash);
    ok($hash->{helper}{opening}, 'connect pending');
    change_disable($hash, 1);
    my $pending = shift @open_callbacks;
    $hash->{TCPDev} = {};
    $pending->[1]->($hash, undef);
    ok(!DevIo_IsOpen($hash), 'late completion closed');
    ok(!exists $hash->{helper}{opening}, 'pending connect flag released');
    is(scalar @writes, 0, 'no writes on late completion');
    $defer_open = 0;
};

subtest 'Disable: rapid re-enable does not start overlapping connects' => sub {
    my $hash = new_receiver();
    $defer_open = 1;
    PIONEERAVR_Reopen($hash);
    change_disable($hash, 1);
    my $before = $open_calls;
    change_disable($hash, 0);
    drain_send_timers();
    is($open_calls, $before, 'wait for pending callback instead of second connect');
    my $pending = shift @open_callbacks;
    $hash->{TCPDev} = {};
    $hash->{READINGS}{state}{VAL} = 'opened';
    $attr{$hash->{NAME}}{statusUpdateReconnect} = 'disable';
    $pending->[1]->($hash, undef);
    drain_send_timers();
    ok(DevIo_IsOpen($hash), 'completed connection retained after re-enable');
    ok(!exists $hash->{helper}{opening}, 'pending flag cleared');
    $defer_open = 0;
};

subtest 'Disable: one receiver does not pause another' => sub {
    my $first = new_receiver();
    my $second = {NAME => 'test.second', TYPE => 'PIONEERAVR'};
    $defs{'test.second'} = $second;
    PIONEERAVR_Define($second, ['test.second','PIONEERAVR','telnet','second.invalid:8000'], {});
    PIONEERAVR_Write($second, '?P');
    PIONEERAVR_Write($second, '?M');
    change_disable($first, 1);
    drain_send_timers();
    is_deeply(commands(), ['?P','?M'], 'second queue continues');
    ok(DevIo_IsOpen($second), 'second transport remains open');
};

subtest 'Disable: repeated toggles and undef leave no resume timer' => sub {
    my $hash = new_receiver();
    my $before = $open_calls;
    change_disable($hash, 0);
    drain_send_timers();
    is($open_calls, $before, 'zero on enabled device does not reconnect');
    change_disable($hash, 1);
    change_disable($hash, 0);
    change_disable($hash, 1);
    drain_send_timers();
    is($open_calls, $before, 'disable cancels scheduled resume');
    change_disable($hash, 0);
    PIONEERAVR_Undef($hash, '');
    delete $defs{$hash->{NAME}};
    drain_send_timers();
    is($open_calls, $before, 'undef cancels scheduled resume');
};

subtest 'Disable: own reading notifications do not recurse' => sub {
    my $hash = new_receiver();
    my $events = 0;
    {
        no warnings qw(redefine once);
        local *main::readingsEndUpdate = sub {
            die "Recursive disabled events\n" if ++$events > 5;
            $hash->{CHANGED} = ['state: disabled'];
            PIONEERAVR_Notify($hash, $hash);
        };
        change_disable($hash, 1);
        PIONEERAVR_StopCommunication($hash);
    }
    is($events, 1, 'disabled readings emitted once despite self-notification');
};

subtest 'Disable: deleting all attributes resumes after storage' => sub {
    my $hash = new_receiver();
    change_disable($hash, 1);
    $attr{$hash->{NAME}}{powerSupplyDevice} = 'test.power:state';
    $defs{'test.power'}{READINGS}{state}{VAL} = 'off';
    is(PIONEERAVR_Attr('del', $hash->{NAME}, undef, undef), undef,
       'delete all accepted');
    delete $attr{$hash->{NAME}};
    drain_send_timers();
    ok(DevIo_IsOpen($hash), 'removed power supply attribute cannot prevent resume');
};

subtest 'Status reading: running through final input write, then done' => sub {
    my $hash = new_receiver();
    PIONEERAVR_statusUpdate($hash);
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'running', 'running immediately');
    while (scalar(@writes) < 405) { run_next_send_timer(); }
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'running', 'still running before final request');
    run_next_send_timer();
    is(commands()->[-1], '?ILA59', 'final input query sent');
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'done', 'done after all 406 queries');
    ok(!$hash->{helper}{statusRequest}, 'tracking released');
};

subtest 'Status reading: repeated requests coalesce during input scan' => sub {
    my $hash = new_receiver();
    PIONEERAVR_statusUpdate($hash);
    while (scalar(@writes) < 60) { run_next_send_timer(); }
    PIONEERAVR_statusUpdate($hash);
    drain_send_timers();
    is(scalar(@writes), 406, 'no second status batch appended');
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'done', 'shared request done');
    @writes = ();
    PIONEERAVR_statusUpdate($hash);
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'running', 'new request starts after completion');
    drain_send_timers();
    is(scalar(@writes), 406, 'new request is complete');
};

subtest 'Status reading: disable aborts without replay' => sub {
    my $hash = new_receiver();
    PIONEERAVR_statusUpdate($hash);
    change_disable($hash, 1);
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'aborted', 'disabled scan aborted');
    drain_send_timers();
    is(scalar(@writes), 1, 'no more scan queries sent');
    PIONEERAVR_statusUpdate($hash);
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'aborted', 'rejected request does not set running');
};

subtest 'Status reading: disconnect during final write cannot report done' => sub {
    my $hash = new_receiver();
    PIONEERAVR_statusUpdate($hash);
    while (scalar(@writes) < 405) { run_next_send_timer(); }
    {
        no warnings qw(redefine once);
        local *main::DevIo_SimpleWrite = sub { DevIo_Disconnected($_[0]); };
        run_next_send_timer();
    }
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'aborted', 'transport failure wins over done');
    ok(!$hash->{helper}{statusRequest}, 'tracking released after disconnect');
};

subtest 'Status reading: independent input discovery does not create a full request' => sub {
    my $hash = new_receiver();
    PIONEERAVR_askForInputNames($hash, 5);
    drain_send_timers();
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', 'missing'), 'missing', 'no misleading full-status reading');
    PIONEERAVR_askForInputNames($hash, 5);
    PIONEERAVR_statusUpdate($hash);
    drain_send_timers();
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'done', 'existing input scan joins full request');
};

subtest 'Status reading: automatic reconnect uses same lifecycle' => sub {
    my $hash = new_receiver();
    PIONEERAVR_AfterOpen($hash, 1);
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'running', 'automatic status running');
    drain_send_timers();
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', ''), 'done', 'automatic status done');
};

subtest 'Status reading: unavailable receiver cannot start a request' => sub {
    my $hash = new_receiver();
    delete $hash->{TCPDev};
    PIONEERAVR_statusUpdate($hash);
    is(ReadingsVal($hash->{NAME}, 'statusRequestState', 'missing'), 'missing', 'closed receiver does not start');
    is(scalar(@writes), 0, 'no traffic');
};

subtest 'Set arguments: inputSkip accepts zero and preserves validation' => sub {
    for my $case (
        ['0', '010300SSC'], ['1', '010301SSC'],
        [undef, undef], ['2', undef]
    ) {
        my ($value, $expected) = @$case;
        my $hash = new_receiver();
        my @arguments = ($hash->{NAME}, 'inputSkip', 'cd');
        push @arguments, $value if defined $value;
        my $result = PIONEERAVR_Set($hash, \@arguments, {});
        drain_send_timers();
        if (defined $expected) {
            is($result, undef, "inputSkip $value accepted");
            is_deeply(commands(), [$expected], "inputSkip $value sends exact command");
        }
        else {
            like($result, qr/Could not modify inputSkip/, 'missing or invalid value rejected');
            is_deeply(commands(), [], 'rejected inputSkip sends nothing');
        }
    }
};

subtest 'Set arguments: zero-valued input alias is selectable' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "RGB0110\r\n");
    is(PIONEERAVR_Set($hash, [$hash->{NAME}, 'input', '0'], {}), undef,
       'input alias 0 accepted');
    drain_send_timers();
    is_deeply(commands(), ['01FN'], 'alias 0 selects input 01');
};

subtest 'Set arguments: numeric zero sends correct commands without warnings' => sub {
    for my $case (
        ['volume', '000VL'], ['volumeStraight', '161VL'],
        ['bass', '06BA'], ['treble', '06TR']
    ) {
        my ($command, $expected) = @$case;
        my $hash = new_receiver();
        my @warnings;
        my $result;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $result = PIONEERAVR_Set($hash, [$hash->{NAME}, $command, '0'], {});
            drain_send_timers();
        }
        is($result, undef, "$command 0 accepted");
        is_deeply(commands(), [$expected], "$command 0 has correct wire value");
        is_deeply(\@warnings, [], "$command 0 does not become an empty numeric value");
    }
};

subtest 'Network standby: complete replies update reading and legacy internal' => sub {
    my $hash = new_receiver();
    delete $hash->{READINGS}{networkStandby};
    feed_receiver($hash, "STJ");
    is(ReadingsVal($hash->{NAME}, 'networkStandby', 'missing'), 'missing', 'fragment does not invent a state');
    feed_receiver($hash, "0\r\n");
    is(ReadingsVal($hash->{NAME}, 'networkStandby', ''), 'off', 'STJ0 reading off');
    is($hash->{networkStandby}, 'off', 'legacy internal off');
    feed_receiver($hash, "STJ1\r\n");
    is(ReadingsVal($hash->{NAME}, 'networkStandby', ''), 'on', 'STJ1 reading on');
    is($hash->{networkStandby}, 'on', 'legacy internal on');
    feed_receiver($hash, "STJ|\r\nSTJ0invalid\r\n");
    is(ReadingsVal($hash->{NAME}, 'networkStandby', ''), 'on', 'invalid replies do not change reading');
    is($hash->{networkStandby}, 'on', 'invalid replies do not change internal');
};

subtest 'Network standby: off rejects before any writes or queued commands' => sub {
    my $hash = new_receiver();
    feed_receiver($hash, "STJ0\r\n");
    my $result = PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {});
    like($result, qr/NetworkStandby.*off/, 'known off rejected');
    drain_send_timers();
    is_deeply(commands(), [], 'no wake-up or power-on bytes sent later');
};

subtest 'Network standby: legacy internal fallback works before first reading' => sub {
    for my $state ('off', 'on') {
        my $hash = new_receiver();
        delete $hash->{READINGS}{networkStandby};
        $hash->{networkStandby} = $state;
        my $result = PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {});
        drain_send_timers();
        if ($state eq 'off') {
            like($result, qr/NetworkStandby.*off/, 'legacy off rejected');
            is_deeply(commands(), [], 'legacy off sends nothing');
        }
        else {
            is($result, undef, 'legacy on accepted');
            is_deeply(commands(), ['', '', "\n\rPO", "\n\rPO"], 'legacy on keeps established wake-up sequence');
        }
    }
};

subtest 'Network standby: unknown state allows an attempt' => sub {
    my $hash = new_receiver();
    delete $hash->{READINGS}{networkStandby};
    delete $hash->{networkStandby};
    is(PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {}), undef, 'unknown does not block power-on');
    drain_send_timers();
    is_deeply(commands(), ['', '', "\n\rPO", "\n\rPO"], 'unknown keeps established wake-up sequence');
};

subtest 'Network standby: reading takes precedence over legacy fallback' => sub {
    my $hash = new_receiver();
    $hash->{networkStandby} = 'off';
    is(PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {}), undef, 'confirmed reading on wins');
    drain_send_timers();
    is(scalar(@writes), 4, 'power-on sequence sent');
    @writes = ();
    $hash->{READINGS}{networkStandby}{VAL} = 'off';
    $hash->{networkStandby} = 'on';
    like(PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {}), qr/NetworkStandby.*off/, 'confirmed reading off wins');
    drain_send_timers();
    is_deeply(commands(), [], 'rejected sequence never enters queue');
};

subtest 'Network standby: set waits for receiver confirmation' => sub {
    my $hash = new_receiver();
    is(PIONEERAVR_Set($hash, [$hash->{NAME}, 'networkStandby', 'off'], {}), undef, 'set off accepted');
    drain_send_timers();
    is_deeply(commands(), ['0STJ'], 'existing set command preserved');
    is(ReadingsVal($hash->{NAME}, 'networkStandby', ''), 'on', 'reading not changed optimistically');
    feed_receiver($hash, "STJ0\r\n");
    is(ReadingsVal($hash->{NAME}, 'networkStandby', ''), 'off', 'reply confirms off');
};

subtest 'Network standby: serial power-on works with network standby off' => sub {
    my $hash = new_receiver();
    $hash->{Protocol} = 'serial';
    feed_receiver($hash, "STJ0\r\n");
    is(PIONEERAVR_Set($hash, [$hash->{NAME}, 'on'], {}), undef, 'serial does not require network standby');
    drain_send_timers();
    is_deeply(commands(), ['', '', "\n\rPO", "\n\rPO"], 'serial power-on sequence preserved');
};

subtest 'Metadata registration preserves module callbacks' => sub {
    plan skip_all => 'Metadata registration is not part of the historical baseline'
      if $baseline;
    @metadata_initializations = ();
    my ($receiver_module, $zone_module) = ({}, {});
    is(PIONEERAVR_Initialize($receiver_module), undef, 'receiver initializes');
    is(PIONEERAVRZONE_Initialize($zone_module), undef, 'zone initializes');
    is(scalar(@metadata_initializations), 2, 'both modules register metadata');
    like($metadata_initializations[0][0], qr/70_PIONEERAVR\.pm\z/, 'receiver source path registered');
    like($metadata_initializations[1][0], qr/71_PIONEERAVRZONE\.pm\z/, 'zone source path registered');
    is(refaddr($metadata_initializations[0][1]), refaddr($receiver_module), 'receiver module hash passed');
    is(refaddr($metadata_initializations[1][1]), refaddr($zone_module), 'zone module hash passed');
    is($receiver_module->{DefFn}, 'PIONEERAVR_Define', 'receiver callback preserved');
    is($zone_module->{DefFn}, 'PIONEERAVRZONE_Define', 'zone callback preserved');
};

done_testing();
