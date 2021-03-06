#!/usr/bin/perl -w
# kate: space-indent on; indent-width 4; mixedindent off; indent-mode cstyle; 

my $MAKE = "make -C buildroot";
my $URL = "http://sysmic.org/~jezz/autobuilder";
# Three main data:
#   %cfgs iterator: $c
#   %pkgs iterator: $p $dep $depdep
#   @jobs iterator: $j


#package {
#  dir =>
#  name =>
#  ctime =>
#  cfgs => ( $cfg{name} => {
#             cfg =>
#             depends =>
#             rdepends =>
#             depends_recurs =>
#             rdepends_recurs =>
#             modified => TODO
#             forced => TODO
#             status => TODO
#  }
#)
# cfg {
#   name =>
#   dir =>
#   inhibit =>
#   pkgs => ( )
# }

$ENV{LANG} = "C";

use strict;
use File::Basename;
use POSIX qw(strftime);
use Cwd qw(realpath);
use MIME::Lite;
use Template;
use List::MoreUtils qw(uniq);

my $tpl = Template->new({ POST_CHOMP => 1, ENCODING => 'utf8' });
my $report = "";
my $reporttime = time;
my $changereport = "";

( -e "buildroot" ) || die "buildroot/ does not exist";
( -e "buildroot/.git" ) || die "buildroot/ is not managed by git";

# Change mail configuration for report as needed
sub sendReport {
    $reporttime = time; 
    if ($report)  {
        my $msg = MIME::Lite->new(
            From     => 'autobuilder@sysmic.org',
            To       => 'jezz@sysmic.org',
            # Cc       => 'list@buildroot.net',
            Subject  => "Autobuild report of " . (strftime "%F", gmtime $reporttime),
            Data     => $report
        );
        $msg->send;
        $report = "";
    }
}

sub sendChangeReport {
    if ($changereport)  {
        my $msg = MIME::Lite->new(
            From     => 'autobuilder@sysmic.org',
            To       => 'jezz@sysmic.org',
            # Cc       => 'list@buildroot.net',
            Subject  => "Autobuild changes in configs",
            Data     => $changereport
        );
        $msg->send;
        $changereport = "";
    }
}

# Print message with timestamp
sub pr(@) {
    print ((strftime "%T ", localtime(time)) . "@_\n");
}

# Return modification time of one file
sub mtime($) {
    return 0 if (!-e $_[0]);    
    return (stat $_[0])[9];
}

# Return first line of one file
sub firstLine($) {
    return undef if (! -e $_[0]);
    my $FILE;
    open ($FILE, '<', $_[0]) || die "$_[0]: $!";
    my $line = <$FILE>;
    close $FILE;
    chomp $line || print "Cannot chomp $line";
    return $line
}

# Write a line in a file
sub writeLine($$) {
    my $FILE;
    open ($FILE, '>', $_[0]) || die "$_[0]: $!";
    print { $FILE } $_[1] . "\n";
    close $FILE;
}

sub file_grep($$) {
    my $string1 = $_[0];
    my $srce = $_[1];

    open my $fh, $srce or die "Could not open $srce: $!";

    my $result = grep /$string1/, <$fh>;
    return $result;
}

sub getPkgList() {
  my %list;
  for my $file (<buildroot/*/*.mk buildroot/*/*/*.mk buildroot/package/*/*/*.mk>) {
     my $filepattern = $file;
     $filepattern =~ tr|-|_|;
     next if ($filepattern !~ m|(.*)/\1.mk$|);
     $file =~ m|(.*)/\1.mk$|;
     my $name = $1;
     # Blacklist building of linux-headers since it break scsi/sg.h
     next if ($name eq "linux-headers");
     my $FILE;
     open $FILE, $file;
     while (<$FILE>) {
        if (/\$\(eval \$\(host-[a-z]*-package\)\)/) {
           $list{"host-$name"}{dir} = dirname $file;
           $list{"host-$name"}{dir} =~ s|^buildroot/||;
           $list{"host-$name"}{name} = "host-$name";
           $list{"host-$name"}{cfgs} = { };
           $list{"host-$name"}{ctime} = 0;
        }
        if (/\$\(eval \$\([a-z]*-package\)\)/) {
	   $list{"$name"}{dir} = dirname $file;
           $list{"$name"}{dir} =~ s|^buildroot/||;
	   $list{"$name"}{name} = $name;
           $list{"$name"}{cfgs} = { };
           $list{"$name"}{ctime} = 0;
	}
     }
     close $FILE;
  }
  return \%list;
}

sub getCfgList() {
    my %list;
    for (<cfgs/*/.config>) {
        my ($name) = m|cfgs/(.*)/.config|;
        $list{$name}{name} = "$name";
        $list{$name}{dir} = "../cfgs/$name";
        $list{$name}{inhibit} = (-e "cfgs/$name/inhibit") ? 1 : 0;
        $list{$name}{mtime} = mtime "cfgs/$name/.config";
        $list{$name}{packages} = [ ];
        my $FILE;
        open $FILE, "cfgs/$name/.config";
        while (<$FILE>) {
            $list{$name}{arch} = $1 if /^BR2_ARCH="(.*)"$/;
            $list{$name}{libc} = "glibc" if /^BR2_TOOLCHAIN_USES_GLIBC=y$/;
            $list{$name}{libc} = "uclibc" if /^BR2_TOOLCHAIN_USES_UCLIBC=y$/;
            $list{$name}{toolchain} = "external" if /^BR2_TOOLCHAIN_EXTERNAL=y$/;
            $list{$name}{toolchain} = "buildroot" if /^BR2_TOOLCHAIN_BUILDROOT=y$/;
        }
        close $FILE;
    }
    return \%list;
}

# Travailler sur les commitData
# Update Commit time of each package directories
#... Long... around 3min. Necessary only if git pull returned something.
sub updateCTimes($) {
    my %pkgs = %{$_[0]};
    for my $name (keys %pkgs) {
        next if ($name =~ /^host-(.*)$/ && $pkgs{$1});
        my $time = qx(cd buildroot && git log --pretty="%ct" -1 $pkgs{$name}{dir});
        chomp $time;
        $pkgs{"$name"}{ctime} = $time if $pkgs{"$name"};
        $pkgs{"host-$name"}{ctime} = $time if $pkgs{"host-$name"};
    }
}

# Long : around 20s per config (4min for all configurations)
# Split target and depends
sub updateTargetsAndDeps($$) {
    # Link a configuration with a Package
    sub addPkgConfig($$) {
        my $cfg = $_[0];
        my $pkg = $_[1];
        print "$pkg->{name} name is invalid\n" if (!$pkg->{name});
        push @{$cfg->{packages}}, $pkg;
        $pkg->{cfgs}{$cfg->{name}} = {
            pkg => $pkg,
            cfg => $cfg,
            rdepends => [ ],
            depends => [ ],
            depends_recurs => [ ],
            rdepends_recurs => [ ]
        };
    }

    sub getTargets($) {
        my $cfg = $_[0];
        pr "run (take around 4s): make -s O=$cfg->{dir} show-targets";
        my @packages = split / /, qx($MAKE -s O=$cfg->{dir} show-targets);
        chomp(@packages);
        @packages = grep {!/^target-/} @packages;
        @packages = grep {!/^rootfs-/} @packages;
        @packages = uniq  @packages;
        return @packages;
    }

    sub getDepends($$) {
        my $cfg = $_[0];
        my $packages = $_[1];
        my @args;
        my @result;
        for my $pkg (@{$packages}) {
            push @args, "$pkg-show-depends"
        }
        pr "run (take around 15s): make -s O=$cfg->{dir} ...-show-depends";
        @result = split /\n/, qx($MAKE -s O=$cfg->{dir} @args), -1;
        s/\bcurl\b/libcurl/ for @result;
        return @result;
    }

    sub computeRecursiveDepends($$) {
        my $cfg = $_[0];
        my $type = $_[1]; # Should be depends_recurs or rdepends_recurs
        my $modified = 1;
        my $cname = $cfg->{name};
        while ($modified == 1) {
            pr "Compute recursive depends ($type)";
            $modified = 0;
            for my $pkg (@{$cfg->{packages}}) {
                my $depends = $pkg->{cfgs}{$cname}{$type};
                for my $dpkg (@$depends) {
                    my $ddepends = $dpkg->{cfgs}{$cname}{$type};
                    for my $ddpkg (@$ddepends) {
                        if (!(grep { $_ == $ddpkg } @{$depends})) {
                            push @{$pkg->{cfgs}{$cname}{$type}}, $ddpkg;
                            $modified = 1;
                        }
                    }
                }
            }
        }
    }
  
    my $cfg = $_[0];
    my $pkgs = $_[1];

    my @packages =  grep { if (defined $pkgs->{$_}) { 1; } else { print "Warning $_ unknown but referenced by $cfg->{name}. Drop it\n"; 0; } } getTargets($cfg);
    $cfg->{packages} = [ ];
    for my $pkg (@packages) {
        if (! defined $pkgs->{$pkg} || ! $pkgs->{$pkg}{name}) {
            print "$cfg->{name} reference a a non registered package $pkg\n";
        }
        addPkgConfig $cfg, $pkgs->{$pkg};
    }
    my @all_deps = getDepends($cfg, \@packages);
    
    for my $pkg (@packages) {
        my @pkg_deps = split / /, shift @all_deps;
        for my $dep (@pkg_deps) {
            if (!defined $pkgs->{$dep}{cfgs}{$cfg->{name}}) {
                if (!defined $pkgs->{$dep} || ! $pkgs->{$dep}{name}) {
                    print "Error: $pkg depends of $dep, but $dep does not exist!?\n";
                    next;
                } else {
                    #print "Warning $pkg depends of $dep, but $dep was not in targets. Add it\n";
                    addPkgConfig $cfg, $pkgs->{$dep};
                }
            }
            my $pconf = $pkgs->{$pkg}{cfgs}{$cfg->{name}};
            my $rpconf = $pkgs->{$dep}{cfgs}{$cfg->{name}};
            push @{$pconf->{depends}},          $pkgs->{$dep};
            push @{$pconf->{depends_recurs}},   $pkgs->{$dep};
            push @{$rpconf->{rdepends}},        $pkgs->{$pkg};
            push @{$rpconf->{rdepends_recurs}}, $pkgs->{$pkg};
        }
    }

    computeRecursiveDepends $cfg, "depends_recurs";
    computeRecursiveDepends $cfg, "rdepends_recurs";
}

sub updateInhibit($) {
    my $cfgs = $_[0];
    my $ret = 0;
    for my $c (values %{$cfgs}) {
        my $newvalue = (-e "cfgs/$c->{name}/inhibit") ? 1 : 0;
        if (!defined $c->{inhibit} || $c->{inhibit} != $newvalue) {
            $c->{inhibit} = $newvalue;
            $ret = 1;
        }
    }
    return $ret;
}

sub updateForce($) {
    my $pkgs = $_[0];
    my $ret = 0;
    for my $p (values %{$pkgs}) {
        for my $j (values %{$p->{cfgs}}) {
            my $dir = "context/$j->{cfg}{name}/$j->{pkg}{name}";
            if (-e $dir) {
                my $newvalue = (-e "$dir/force-rebuild") ? 1 : 0;
                if ($j->{forcerebuilt} != $newvalue) {
                    $j->{forcerebuilt} = $newvalue;
                    $ret = 1;
                }
            }
        }
    }
    return $ret;
}

sub updateStatus($) {
    my $pkgs = $_[0];
    for my $p (values %{$pkgs}) {
        for my $j (values %{$p->{cfgs}}) {
            print "BUG context/$j->{cfg}{name} / $j->{pkg}{name} / $p->{name}\n" if (! $p->{name} || ! $j->{pkg}{name});
            next if (! $p->{name} || ! $j->{pkg}{name});
            my $dir = "context/$j->{cfg}{name}/$j->{pkg}{name}";
            if (-e $dir) {
                #print "Detect context/$cfg{cfg}/$pkg{name}\n";
                $j->{last_build}{id}       = basename (realpath $dir);
                $j->{last_build}{date}     = firstLine "$dir/date";
                $j->{last_build}{duration} = firstLine "$dir/duration";
                $j->{last_build}{gitid}    = firstLine "$dir/gitid";
                $j->{last_build}{result}   = firstLine "$dir/result";
                $j->{last_build}{outdirid} = firstLine "$dir/outdirid";
                $j->{forcerebuilt} = ((-e "$dir/force-rebuild") ? 1 : 0);
                $j->{last_build}{details}  = firstLine "$dir/details";
            }
        }
    }
}

sub getJobs($) {
    sub computePriority {
        my %p =  %{$_[0]};
        return 100 if ($p{forcerebuilt});
        return 80 if (defined $p{last_build} && $p{last_build}{result} eq "Failed" && $p{pkg}{ctime} > $p{last_build}{date});
        return 60 if (!defined $p{last_build});
        return 40 if ($p{pkg}{ctime} > $p{last_build}{date});
        for my $d (@{$p{depends_recurs}}) {
            return 30 if $d->{ctime} > $p{last_build}{date};
        }
        return 0;
    }
    sub sortJobs {
        my $prioa = $a->{priority};
        my $priob = $b->{priority};
        return $priob <=> $prioa if ($priob != $prioa);
        # Try to build package without deps in first.
        # TODO: Make a real topologic sort
        if (@{$a->{depends_recurs}} > 0 && @{$b->{depends_recurs}} == 0) {
            return 1;
        }
        if (@{$b->{depends_recurs}} > 0 && @{$a->{depends_recurs}} == 0) {
            return -1;
        }
        if (grep { $_ == $a->{pkg} } @{$b->{depends_recurs}}) {
            return 1;
        }
        if (grep { $_ == $b->{pkg} } @{$a->{depends_recurs}}) {
            return -1;
        }
        
        if ($a->{last_build} && $b->{last_build} && $a->{last_build}{date} != $b->{last_build}{date}) {
            return $a->{last_build}{date} <=> $b->{last_build}{date};
        }
        return $a->{cfg}{name} cmp $b->{cfg}{name} if $a->{cfg}{name} cmp $b->{cfg}{name};
        return $a->{pkg}{name} cmp $b->{pkg}{name};
    }
    
    my %pkgs = %{$_[0]};
    my @jobs;
    for my $p (values %pkgs) {
        for my $c (values $p->{cfgs}) {
            if (!$c->{inhibit}) {
                $c->{priority} = computePriority $c;
                push @jobs, $c;
            }
        }
    }
    @jobs = sort sortJobs @jobs;
    return \@jobs;
}

############# HTML #############
sub resultToHtml($) {
    my $res = $_[0];

    return "<td class='blue'>N/A</td>" if !(defined $res);
    return "<td class='blue'>Wait</td>" if !(defined $res->{last_build});
    my $dir = "../results/$res->{last_build}{id}";
    my $result = $res->{last_build}{result};
    return "<td class='green'><a href='$dir'>OK</a></td>" if ($result eq "OK" ||  $result eq "Ok");
    return "<td class='red'><a href='$dir'>KO</a></td>"   if ($result eq "KO" ||  $result eq "Failed");
    return "<td class='orange'><a href='$dir'>Dep</a><br/><a class='small' href='$res->{last_build}{details}.html'>$res->{last_build}{details}</a></td>" if ($result eq "Dep");
    return "<td class='blue'><a href='$dir'>$result</a></td>";
    #return "<td class='blue'>BUG</td>";
}

sub gitIdToHtml($) {
    my $gitid = $_[0];
    return "<td><a class='gitid' href='http://git.buildroot.net/buildroot/commit/?id=$gitid'>" . (substr $gitid, 0, 7) . "</a></td>";
}

sub dumpPkg($) {
    my %pkg = %{$_[0]};
    for my $c (sort keys %{$pkg{cfgs}}) {
        if (defined $pkg{cfgs}{$c}{last_build}) {
            my $dir = "results/$pkg{cfgs}{$c}{last_build}{id}";
            my $idx = 0;
            $pkg{cfgs}{$c}{html_result} = "";
            while (-e "$dir") {
                my %res;
                $res{last_build}{id}       = basename (realpath $dir);
                $res{last_build}{result}   = firstLine "results/$res{last_build}{id}/result";
                $res{last_build}{details}  = firstLine "results/$res{last_build}{id}/details";
                $res{last_build}{duration} = firstLine "results/$res{last_build}{id}/duration";
                $res{last_build}{date}     = firstLine "results/$res{last_build}{id}/date";
                $pkg{cfgs}{$c}{html_result} .= "<tr><td>$idx</td>";
                $pkg{cfgs}{$c}{html_result} .= resultToHtml \%res;
                $pkg{cfgs}{$c}{html_result} .= "<td>" . (strftime "%F", gmtime $res{last_build}{date}) . "</td>";
                $pkg{cfgs}{$c}{html_result} .= gitIdToHtml(firstLine "results/$res{last_build}{id}/gitid");
                $pkg{cfgs}{$c}{html_result} .= "<td>$res{last_build}{duration}</td></tr>\n";
                $dir = "results/$res{last_build}{id}/previous_build";
                $idx++;
            }
        }
    }
    $tpl->process("package.html.in", { name => $pkg{name}, cfgs => $pkg{cfgs} }, "html/$pkg{name}.html") || die $tpl->error();
}

sub dumpCfgs($) {
    my ($cfgs) = @_;

    for my $c (values %{$cfgs}) {
        $tpl->process("config.html.in", { cfg => $c }, "html/cfg-$c->{name}.html") || die $tpl->error();
    }
}

sub dumpResults($$) {
    my ($cfgs, $pkgs) = @_;

    for my $p (values %{$pkgs}) {
        $p->{html_result} = "";
        for my $c (sort keys %{$cfgs}) {
            $p->{html_result} .= resultToHtml($p->{cfgs}{$c}) . "\n";
        }
    }
    $tpl->process("index.html.in", { cfgs => $cfgs, pkgs => $pkgs }, "html/index.html") || die $tpl->error();
}


sub dumpJobQueue($$) {
    my @jobs = @{$_[0]};
    my $current_idx = $_[1];
    my $idx = 0;
    for my $r (@jobs) {
        $r->{html_result} = "<tr>";
        if ($idx == $current_idx) {
            $r->{html_result} .= "<td><b>=&gt; $idx </b></td>";
        } else {
            $r->{html_result} .= "<td>$idx</td>";
        }
        $r->{html_result} .= "<td><a href='$r->{pkg}{name}.html'>$r->{pkg}{name}</td>";
        $r->{html_result} .= "<td><a href='cfg-$r->{cfg}{name}.html'>$r->{cfg}{name}</a></td>";
        $r->{html_result} .= resultToHtml($r);
        
        if ($r->{forcerebuilt}) {
            $r->{html_result} .= "<td>Force rebuild</td>";
        } elsif (!(defined $r->{last_build})) {
            $r->{html_result} .= "<td>Never built</td>";
        } elsif ($r->{pkg}{ctime} > $r->{last_build}{date}) {
            $r->{html_result} .= "<td>Modified</td>";
        } else {
            my $done = 0;
            $r->{html_result} .= "<td>";
            for my $d (@{$r->{depends_recurs}}) {
                if ($d->{ctime} > $r->{last_build}{date}) {
                    $r->{html_result} .= "Dep ($d->{name}) modified<br/>";
                    $done = 1; 
                }
            }
            if (!$done) {
                $r->{html_result} .= "Normal";
            }
            $r->{html_result} .= "</td>";
        }
        if ($r->{last_build}) {
            $r->{html_result} .= "<td>" . (strftime "%F", gmtime $r->{last_build}{date}) . "</td>";
            $r->{html_result} .=  gitIdToHtml $r->{last_build}{gitid};
            $r->{html_result} .= "<td>$r->{last_build}{duration}</td></tr>\n";
        } else {
            $r->{html_result} .= "<td>N/A</td>";
            $r->{html_result} .= "<td>N/A</td>";
            $r->{html_result} .= "<td>N/A</td></tr>\n";
        }
        $idx++;
    }
    $tpl->process("jobqueue.html.in", { jobs => \@jobs }, "html/jobqueue.html") || die $tpl->error();
}


############# BUILD #############
sub buildPkg($$$) {
    my ($cfg, $pkg, $out) = @_; 
    my $ret;
    $ret = system "$MAKE O=$cfg $pkg-dirclean > $out/build_log 2>&1";
    if (!$ret) {
        $ret = system "$MAKE O=$cfg toolchain $pkg >> $out/build_log 2>&1";
    }
    if ($ret >> 8) {
        my $FILE;
        my ($dep_pkg, $dep_step);
        open $FILE, "$out/build_log";
        my $reason = (grep /^\[7m>>> .*\[27m$/, <$FILE>)[-1];
        if ($reason) {
            $reason =~  /^\[7m>>> ([^ ]*) ([^ ]*) (.*)\[27m/;
            ($dep_pkg, $dep_step) = ($1, $3);
        } else {
            ($dep_pkg, $dep_step) = ("Configuration error", "checking");
        }
        close $FILE;
        print "Build of $pkg failed because of $dep_pkg while $dep_step\n";
        if ($dep_pkg ne $pkg) {
            writeLine "$out/details", "$dep_pkg";
            writeLine "$out/result", "Dep";
        } else {
            writeLine "$out/result", "KO";
        }
    } elsif ($ret == 2) {
        print "Build of $pkg interrupted\n";
        writeLine "$out/result", "Interrupted";
    } elsif ($ret) {
        print "Build of $pkg had a strange end\n";
        writeLine "$out/result", "BUG";
    } else {
        print "Build of $pkg success\n";
        writeLine "$out/result", "OK";
    }
    return $?;
}

sub build($$$) {
    my $CMD;
    my ($j, $jobs, $jobidx) = @_; 
    my $cname = $j->{cfg}{name};
    my $pname = $j->{pkg}{name};
    my $new_id = qx(uuidgen | cut -f 1 -d '-');
    chomp $new_id;
    my $old_id;;
    $old_id = $j->{last_build}{id} if $j->{last_build};
    print "Building: $cname/$pname " . ($old_id ? $old_id : "") . "->$new_id\n";
    my $time = time;
    mkdir "results" if (! -e "results");
    mkdir "context" if (! -e "context");
    mkdir "context/$cname" if (! -e "context/$cname");
        
    writeLine "cfgs/$cname/dirid", qx(uuidgen | cut -f 1 -d '-')  if (! -e "cfgs/$cname/dirid");
    if ($j->{priority} == 0 && $j->{last_build} && $j->{last_build}{outdirid} && $j->{last_build}{outdirid} eq firstLine "cfgs/$cname/dirid") {
        print "run: $MAKE O=../cfgs/$cname clean\n";
        system "$MAKE O=../cfgs/$cname clean";
        writeLine "cfgs/$cname/dirid", qx(uuidgen | cut -f 1 -d '-');
    }

    my %prev_build;
    if ($j->{last_build}) {
        %prev_build = %{$j->{last_build}};
    } else {
        $prev_build{result} = "Wait";
    }
    $j->{last_build}{id}       = $new_id;
    $j->{last_build}{date}     = $time;
    $j->{last_build}{duration} = "N/A";
    $j->{last_build}{gitid}    = qx(cd buildroot && git rev-parse HEAD);
    $j->{last_build}{result}   = "Cur";
    $j->{last_build}{details}  = undef;
    $j->{last_build}{outdirid} = firstLine "cfgs/$cname/dirid";
    $j->{forcerebuilt}         = 0;

    mkdir "results/$new_id";
    symlink "../$old_id", "results/$new_id/previous_build" if $old_id;
    writeLine "results/$new_id/long_id",  "$cname $pname $time";
    writeLine "results/$new_id/date",     $j->{last_build}{date};
    writeLine "results/$new_id/result",   $j->{last_build}{result};
    writeLine "results/$new_id/outdirid", $j->{last_build}{outdirid};
    writeLine "results/$new_id/gitid",    $j->{last_build}{gitid};
    writeLine "results/$new_id/duration", $j->{last_build}{duration};

    unlink "context/$cname/$pname";
    symlink "../../results/$new_id", "context/$cname/$pname" || die $!;
    dumpPkg $j->{pkg};
    dumpJobQueue($jobs, $jobidx);

    #my $exit_status;
    #if (-x "cfgs/$cname/buildPkg") {
    #    $exit_status = system "cfgs/$cname/buildPkg cfgs/$cname $pname results/$new_id";
    #} else {
    #     $exit_status = buildPkg "../cfgs/$cname", $pname, "results/$new_id";
    #}
    buildPkg "../cfgs/$cname", $pname, "results/$new_id";
    $j->{last_build}{duration} = (time - $time);
    writeLine "results/$new_id/duration", $j->{last_build}{duration};
    $j->{last_build}{result}   = firstLine "results/$new_id/result";
    $j->{last_build}{details}  = firstLine "results/$new_id/details";
    if ($j->{last_build}{result} ne $prev_build{result}) {
        my $explanation = "$j->{pkg}{name}/$j->{cfg}{name} [$URL/$j->{pkg}{name}.html#$j->{cfg}{name}]: $prev_build{result}";
        $explanation .=  " ($prev_build{details})" if ($prev_build{result} eq "Dep");
        #$explanation .=  " [$URL/results/$prev_build{id}]" if ($prev_build{result} ne "Wait");
        $explanation .=  " -> $j->{last_build}{result}";
        $explanation .=  " ($j->{last_build}{details})" if ($j->{last_build}{result} eq "Dep");
        #$explanation .=  " [$URL/results/$j->{last_build}{id}]";
        $explanation .=  "\n";
        $report .= "$explanation";
    }
    dumpPkg $j->{pkg};
    dumpJobQueue($jobs, $jobidx);
}

my $lastchecktime = time;
my $redumpkgs = 0;
my $rebuilddb = 1;
my $pkgs;
my $cfgs;
my $jobidx = 0;
my $jobs;

pr "Get config list";
$cfgs = getCfgList;

while (1) {
    if (time > $reporttime + (3600 * 24)) {
        pr "Send report";
        sendReport;
    }
    pr "Check changes on git";
    my $changes = qx(cd buildroot && git pull 2>&1);
    if ($changes !~ /^.* up.to.date\.$/) {
        $rebuilddb = 1;
        $changereport .= $changes;
        print $changes;
    }

    if ($rebuilddb) {
        pr "Get package list";
        $pkgs = getPkgList;
        pr "Update configurations";
        for my $c (values %$cfgs) {
            if (!$c->{inhibit}) {
                my $changes;
                do {
                    qx(yes "" | $MAKE -s O=../cfgs/$c->{name} oldconfig 2>&1);
                    $changes = qx(~/conf/bin/br_diffconfig cfgs/$c->{name}/.config.old cfgs/$c->{name}/.config);
                    my @options = split /\n/, $changes;
                    for my $line (@options) {
                        if ($line =~ m/\+(PACKAGE_\w*) n/) {
                            my $opt = $1;
                            qx(~/conf/bin/br_config --file cfgs/$c->{name}/.config -e BR2_$opt);
                        }
                    }
                    open my $FH, "cfgs/$c->{name}/.config" || die "Cannot open cfgs/$c->{name}/.config";
                    for my $line (<$FH>) {
                        if ($line =~ /^(BR2_\w*)=y/) {
                            my $opt = $1;
                            if (file_grep "^config $opt\$", "buildroot/Config.in.legacy") {
                                qx(~/conf/bin/br_config --file cfgs/$c->{name}/.config -d $opt);
                            }
                        }
                        if ($line =~ /^(BR2_\w*)=".+"/) {
                            my $opt = $1;
                            if (file_grep "^config $opt\$", "buildroot/Config.in.legacy") {
                                qx(~/conf/bin/br_config --file cfgs/$c->{name}/.config --set-str $opt "");
                            }
                        }
                    }
                    close $FH;
		    # qx(~/conf/bin/br_config --file cfgs/$c->{name}/.config -d BR2_LEGACY);
                    $changes = qx(~/conf/bin/br_diffconfig cfgs/$c->{name}/.config.old cfgs/$c->{name}/.config);
                    $changereport .= $changes;
                    print $changes;
                } while ($changes);
                if (system("$MAKE -s O=../cfgs/$c->{name} core-dependencies > /dev/null")) {
                        $changes = qx($MAKE -s O=../cfgs/$c->{name} core-dependencies 2>&1);
                        $changereport .= $changes;
                        print $changes;
                        writeLine "cfgs/$c->{name}/inhibit", "$changes";
                        $c->{inhibit} = 1;
                };
            }
        }
        pr "Update packets modification times (take 5min)";
        updateCTimes $pkgs;
    }

    sendChangeReport;

    pr "Update inhibit configs";
    $rebuilddb += updateInhibit $cfgs; # TODO: also check new configurations

    my $newtime = time;
    for my $c (values %$cfgs) {
        if (!$c->{inhibit} && (mtime "cfgs/$c->{name}/.config" > $lastchecktime || $rebuilddb)) {
            pr "Update targets and dependencies of $c->{name}";
            updateTargetsAndDeps $c, $pkgs;
            $rebuilddb = 1;
        }
    }
    $lastchecktime = $newtime;

    if ($rebuilddb) {
        pr "Update build status (take 5min)";
        updateStatus $pkgs;    
        pr "Update configs pages";
        dumpCfgs $cfgs;
    }
    
    pr "Dump global status";
    dumpResults $cfgs, $pkgs;    
    if ($redumpkgs && $rebuilddb) {
        pr "Dump packages result (take 20min)";
        for my $p (values %$pkgs) {
            dumpPkg $p;
        }
    }

    pr "Update forced packages";
    $rebuilddb += updateForce $pkgs;

    if ($rebuilddb) {
        pr "Compute job list";
        $jobs = getJobs $pkgs;
        $jobidx = 0;
    } else {
        $jobidx++;
    }
    if ( $jobidx <  scalar @$jobs) {
        pr "Dump job list";
        dumpJobQueue($jobs, $jobidx);
        pr "Build $jobidx: $jobs->[$jobidx]{cfg}{name}/$jobs->[$jobidx]{pkg}{name}";
        build $jobs->[$jobidx], $jobs, $jobidx;
        pr "Rebuild result for $jobs->[$jobidx]{pkg}{name}";
        dumpPkg $jobs->[$jobidx]{pkg};
    } else {
        pr "Waiting for an update....";
        sleep(10);
    }
    $rebuilddb = 0;
}
