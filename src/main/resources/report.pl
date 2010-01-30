# Perl script to generate report of unreleased plugin changes in Hudson's subversion repository.
# @author Alan.Harder@sun.com
# %knownRevs, %skipTag, %skipEntry, %tagMap will be prepended before script is run.
#
# %knownRevs = Map<pluginDir-rev-revcount,message>
#   If plugin "pluginDir" was last released at revision "rev" and there have been "revcount"
#   revisions since then, show the given message in the report instead of the usual message.
#
# %skipTag = Map<tag,anything>
#   Ignore these entries from /svn/hudson/tags.
# %skipEntry = Map<entry,anything>
#   Ignore these entries from /svn/hudson/trunk/hudson/plugins.
#
# %tagMap = Map<tagBase,pluginDir-or-skip>
#   Tags (without "-version#") to either ignore or map to the right pluginDir.

# Get list of all tags, split into plugin name and version:
my $base = 'https://svn.dev.java.net/svn/hudson'; my $tags = "$base/tags";
my $pluginUrl = 'http://fisheye.hudson-ci.org/browse/Hudson/trunk/hudson/plugins';
my @revsUrl = ('http://fisheye.hudson-ci.org/search/hudson/trunk/hudson/plugins/',
               '?ql=select%20revisions%20from%20dir%20/trunk/hudson/plugins/',
               '%20where%20date%20%3E=%20',
               '%20group%20by%20changeset%20return%20csid,%20comment,%20author,%20path');
my $issueUrl = 'http://issues.hudson-ci.org/browse';
my $prefix = $ARGV[0];
my $svn = 'svn --non-interactive';
my $today = &today_val;
my ($ver, $tagrev, $cnt, $d1, $d2, $known, $since, $p, $x, %x);
open(LS,"$svn ls $tags |") or die;
while (<LS>) {
  push(@{$x{$1}}, $2) if m!^(.*)-([\d._]+)/?$! and not exists $skipTag{"$1-$2"};
}
close LS;

# Get "Last Changed Rev" of latest version of each plugin, then get more recent revs in trunk
foreach $x (sort keys %x) {
  next if ($p = exists $tagMap{$x} ? $tagMap{$x} : $x) eq 'skip';
  next if $prefix and $p !~ /^$prefix/;
  $skipEntry{$p} = 1;
  $ver = (sort byver @{$x{$x}})[0];
  ($cnt, $d1, $d2, $known) = &revcount($p,$tagrev=&tagrev("$x-$ver"));
  $_ = "$revsUrl[0]$p$revsUrl[1]$p$revsUrl[2]$d1$revsUrl[3]";
  $p = "[$p|$pluginUrl/$p]";
  print "| $p | | $ver | | | CURRENT\n" if $cnt == 0;
  if ($known or $cnt > 0) {
    $since = "|$_] | since $ver | [r$tagrev|http://hudson-ci.org/commit/$tagrev] |";
    $d1 = &colorize($d1, $today);
    $d2 = &colorize($d2, $today) if $cnt > 1;
    print "| $p | [$cnt rev", ($cnt > 1 ? "s$since $d1 to $d2" : "$since $d1"), " | $known\n";
  }
}

# List unreleased plugins
open(LS,"$svn ls $base/trunk/hudson/plugins |") or die;
while (<LS>) {
  chomp; ($p = $_) =~ s!/$!!;
  next if exists $skipEntry{$p} or ($prefix and $p !~ /^$prefix/);
  ($cnt, $d1, $d2) = &revcount($p,0);
  $_ = "|$revsUrl[0]$p$revsUrl[1]$p$revsUrl[2]$d1$revsUrl[3]] | " . &colorize($d1, $today);
  $d2 = &colorize($d2, $today) if $cnt > 1;
  print "| [$p|$pluginUrl/$p] | [$cnt rev", ($cnt > 1 ? "s$_ to $d2" : $_), " | unreleased\n";
}
close LS;

unless ($prefix) {
  foreach my $key (keys %knownRevs) {
    print "| Unused data in KnownRevs: | | | | $key | $knownRevs{$key}\n";
  }
}

sub byver {
  my ($i,$x,@a,@b);
  @a=split(/[._]/, $a);
  @b=split(/[._]/, $b);
  for ($i=0; $i<@a; $i++) {
    return $x if ($x = $b[$i] <=> $a[$i] or $x = $b[$i] cmp $a[$i]);
  }
  return @b > @a ? 1 : 0;
}

sub tagrev {
  my ($tag, $rev) = ($_[0], '');
  open(TAG, "$svn info $tags/$tag |") or die;
  while (<TAG>) {
    do { $rev = $1; <TAG>; last; } if /^Last Changed Rev:\s*(\d+)/;
  }
  close TAG;
  return $rev;
}

sub revcount {
  my ($plugin, $fromrev, $cnt, $d, $d1, $d2, @fixed) = ($_[0], $_[1]+1, 0);
  open(IN,"$svn log -r $fromrev:HEAD $base/trunk/hudson/plugins/$plugin |") or die;
  while (<IN>) {
    if (/^r\d+ \| [^|]* \| ([\d-]+) /) { $cnt++; $d = $1 }
    if (/^bumping up POM version|prepare for next development iteration/) { $cnt--; $d = '' }
    while (s/FIXED ([A-Z]+-(\d+))//) { push(@fixed, "[$2|$issueUrl/$1]") }
    if (/^---------/ and $d) { $d2 = $d; $d1 = $d unless $d1 }
  }
  close IN;
  $d = delete $knownRevs{"$plugin-".($fromrev-1)."-$cnt"};
  $d = 'Fixed: ' . join(' ', @fixed) unless ($d or !@fixed);
  return ($cnt, $d1, $d2, $d);
}

sub today_val {
  @_ = localtime;
  return $_[5] * 12 + $_[4] + $_[3]/31;
}

sub age_months {
  my @x = split(/-/, $_[0]);
  return $_[1] - (($x[0] - 1900) * 12 + ($x[1] - 1) + $x[2]/31);
}

sub colorize {
  my $a = int(&age_months(@_)/2);
  return $_[0] if $a <= 0;
  $a = 5 if $a > 5;
  @_ = ($_[0], '3', '6', '9', 'c', 'f');
  return '{color:#' . $_[$a] . (9 - $a) . '6}' . $_[0] . '{color}';
}

