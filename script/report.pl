# Perl script to generate report of unreleased plugin changes in Hudson's subversion repository.
# @author Alan Harder (mindless@dev.java.net)
# %knownRevs, %skipTag, %skipEntry, %tagMap, %jsonMap will be prepended before script is run.
#
# %knownRevs = Map<pluginDir-rev-revcount,message> or <pluginDir-unreleased,message>
#                                                  or <pluginId-github,githubRepo>
#   If plugin "pluginDir" was last released at revision "rev" and there have been "revcount"
#   revisions since then, show the given message in the report instead of the usual message.
#   Or pluginDir-unreleased to show given message for an unreleased plugin.
#   Or pluginId-github to specify a plugin is hosted at github.com with given repository name.
#
# %skipTag = Map<tag,anything>
#   Ignore these entries from /svn/hudson/tags.
# %skipEntry = Map<entry,anything>
#   Ignore these entries from /svn/hudson/trunk/hudson/plugins.
#
# %tagMap = Map<tagBase,pluginDir-or-skip>
#   Tags (without "-version#") to either ignore or map to the right pluginDir.
#
# %jsonMap = Map<pluginDir,idInJson>
#   Map to ID used in update-center.json when it doesn't match pluginDir.
use XML::Parser;

my $base = 'https://svn.dev.java.net/svn/hudson';
my ($tags, $tags2) = ("$base/tags", "$base/tags/global-build-stats"); # 1 plugin uses subdir
my @revsUrl = ('http://fisheye.hudson-ci.org/search/hudson/trunk/hudson/plugins/',
               '?ql=select%20revisions%20from%20dir%20/trunk/hudson/plugins/',
               '%20where%20date%20%3E=%20',
               '%20group%20by%20changeset%20return%20csid,%20comment,%20author,%20path');
my $issueUrl = 'http://issues.hudson-ci.org/browse';
my $prefix = $ARGV[0];
my $svn = 'svn --non-interactive';
my $today = &today_val;
my ($ver, $tagrev, $cnt, $d1, $d2, $known, $since, $p, $x, %x, %updateCenter);

# Get list of all svn tags, split into plugin name and version
open(LS,"$svn ls $tags $tags2 |") or die;
while (<LS>) {
  push(@{$x{$1}}, $2) if m!^(.*)-([\d._]+)/?$! and not exists $skipTag{"$1-$2"};
}
close LS;

# Read Update Center data
open(JSON,"$svn cat $base/trunk/www2/update-center.json |") or die;
while (<JSON>) {
  $p = $1 if s/(?:^|{)\s*"(.*?)"\s*:\s*{//;
  $ver = $1 if s/(?:^|,)\s*"version"\s*:\s*"(.*?)"//;
  $x = $1 if s/(?:^|,)\s*"wiki"\s*:\s*"(.*?)"//;
  if (/^    },?\s*$/) {
    $updateCenter{$p} = { 'version' => $ver, 'wiki' => $x };
    $p = $ver = $x = undef;
  }
}
close JSON;
%updateCenter or die "No data from update-center.json";

# Get "Last Changed Rev" of latest version of each plugin, then get more recent revs in trunk
foreach $x (sort bydir keys %x) {
  next if ($p = exists $tagMap{$x} ? $tagMap{$x} : $x) eq 'skip';
  next if $prefix and $p !~ /^$prefix/;
  $skipEntry{$p} = 1;
  $ver = (sort byver @{$x{$x}})[0];
  ($cnt, $d1, $d2, $known) = &revcount($p,$tagrev=&tagrev("$x-$ver"));
  $since = "$revsUrl[0]$p$revsUrl[1]$p$revsUrl[2]$d1$revsUrl[3]";
  ($p,$x) = &updateCenterData($p,$x);
  $x = $ver eq $x ? '' : (($known ? "\n" : " ") . "(_Version mismatch: json has ${x}_)");
  print "| $p | | $ver | | | CURRENT$x\n" if $cnt == 0;
  if ($known or $cnt > 0) {
    $since = "|$since] | since $ver | [r$tagrev|http://hudson-ci.org/commit/$tagrev] |";
    $d1 = &colorize($d1, $today);
    $d2 = &colorize($d2, $today) if $cnt > 1;
    print "| $p | [$cnt rev", ($cnt > 1 ? "s$since $d1 to $d2" : "$since $d1"), " | $known$x\n";
  }
}

# List unreleased plugins
open(LS,"$svn ls $base/trunk/hudson/plugins |") or die;
while (<LS>) {
  chomp; ($p = $_) =~ s!/$!!;
  next if exists $skipEntry{$p} or ($prefix and $p !~ /^$prefix/);
  ($cnt, $d1, $d2) = &revcount($p,0);
  $_ = "|$revsUrl[0]$p$revsUrl[1]$p$revsUrl[2]$d1$revsUrl[3]] | | | " . &colorize($d1, $today);
  $d2 = &colorize($d2, $today) if $cnt > 1;
  $known = delete $knownRevs{"$p-unreleased"};
  $known = 'unreleased' unless $known;
  ($p,$x) = &updateCenterData($p,$p);
  $known .= " (_json data says ${x}_)" if $x;
  print "| $p | [$cnt rev", ($cnt > 1 ? "s$_ to $d2" : $_), " | $known\n";
}
close LS;

# List update center data not reported so far
foreach my $key (keys %updateCenter) {
  next if $prefix and $key !~ /^$prefix/;
  next if ($x = delete $knownRevs{"$key-unreleased"}) eq 'skip';
  ($p,$ver) = &updateCenterData($key,$key);
  $x = &gitRevs($x,$ver) if (!$x and ($x = delete $knownRevs{"$key-github"}));
  $x = 'Found in update-center.json, not in svn' unless $x;
  print "| $p | | $ver | | | $x\n";
}
foreach my $key (keys %knownRevs) {
  next if $prefix and $key !~ /^$prefix/;
  print "| Unused data in KnownRevs: | | | | $key | $knownRevs{$key}\n";
}

sub bydir {
  my ($x,$y) = (exists $tagMap{$a} ? $tagMap{$a} : $a, exists $tagMap{$b} ? $tagMap{$b} : $b);
  lc $x cmp lc $y;
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
  foreach ("$tags/$tag", "$tags2/$tag") {
    open(TAG, "$svn info $_ |") or die;
    while (<TAG>) {
      do { $rev = $1; <TAG>; last; } if /^Last Changed Rev:\s*(\d+)/;
    }
    close TAG;
    last if $rev;
  }
  return $rev;
}

sub revcount {
  my ($plugin, $fromrev, $cnt, $l10n, $d, $d1, $d2, @fixed) = ($_[0], $_[1]+1, 0, 0);
  open(IN,"$svn log -r $fromrev:HEAD $base/trunk/hudson/plugins/$plugin |") or die;
  while (<IN>) {
    if (/^r\d+ \| [^|]* \| ([\d-]+) /) { $cnt++; $d = $1; next }
    if (/prepare for next development iteration|^bumping up POM version/) { $cnt--; $d = '' }
    $l10n++ if /^(integrated )?community[- ]contributed (localization|translation)/i;
    while (s/FIXED ([A-Z]+-(\d+))//i) { push(@fixed, "[$2|$issueUrl/$1]") }
    if (/^---------/ and $d) { $d2 = $d; $d1 = $d unless $d1 }
  }
  close IN;
  $d = delete $knownRevs{"$plugin-".($fromrev-1)."-$cnt"};
  $d = 'Fixed: ' . join(' ', @fixed) unless ($d or !@fixed);
  if ($l10n) {
    if (!$d and $l10n == $cnt) { $d = '~CURRENT -- l10n' }
    elsif (!$d or $d =~ /^Fixed:/) { $d .= ' l10n' }
  }
  return ($cnt, $d1, $d2, $d);
}

sub updateCenterData {
  my ($pluginDir, $tagName) = @_; # Hopefully one of these match the artifactId
  my ($data, $pluginUrl, $version);
  $data = delete $updateCenter{$pluginDir} || delete $updateCenter{$tagName}
                                           || delete $updateCenter{$jsonMap{$pluginDir}};
  $version = $data->{'version'} if $data;
  if ($data->{'wiki'}) {
    $pluginUrl = "[$pluginDir|$data->{wiki}]";
  } else {
    open(IN,"$svn cat $base/trunk/hudson/plugins/$pluginDir/pom.xml 2>/dev/null |") or die;
    map(s|^.*<url>\s*(.*?)\s*</url>.*$|$1|s, @_ = grep(m|<url>.*wiki.*</url>|, <IN>));
    close IN;
    $pluginUrl = @_ > 0 ? "[$pluginDir|$_[0]]" : $pluginDir;
  }
  return ($pluginUrl, $version);
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

sub gitRevs {
  my ($repo, $ver, $doc, $i, $j) = ($_[0], $_[1], XML::Parser->new(Style=>'Tree'));
  open(XML, "curl -s https://github.com/hudson/$repo/commits/master.atom |") or die;
  my ($xml, $done, $count, $rev, $list, $entry, $title) = ($doc->parse(*XML), 0, 0);
  close XML;

  $list = $xml->[1];
  parse: for ($i = 0; $i < $#$list; $i++) {
    if ($list->[$i] eq 'entry') {
      $entry = $list->[++$i];
      for ($j = 0; $j < $#$entry; $j++) {
        if ($entry->[$j] eq 'title') {
          $title = $entry->[++$j]->[2];
          if ($done) {
            $rev = $1 if $title =~ /prepare release.*-([\d._]+)\s*$/;
            last parse;
          } elsif ($title =~ /prepare for next dev/) {
            $done = 1;
          } else {
            $count++;
          }
        }
      }
    }
  }
  $title = $count == 0 ? 'CURRENT' : "[$count rev" . ($count > 1 ? 's' : '')
         . "|https://github.com/hudson/$repo/commits/master/] after release $rev";
  $title .= ' (_Version mismatch' . ($count > 0 ? '' : ": github has ${rev}") . '_)'
    if $rev ne $ver;
  return $title;
}
