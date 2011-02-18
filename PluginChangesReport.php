<?php
# Script to generate report of unreleased plugin changes in Jenkins' plugin repositories.
# @author Alan Harder (mindless@dev.java.net)
$time = time();
#
# $knownRevs of $id-$ver-$cnt => text
# To display a message in the report regarding the state of a plugin.
# Usually to show a message like "~CURRENT -- pom,test" if a plugin's
# changes since the last release don't actually change anything in a
# release (such as pom changes or unit tests).
# For plugin $id with $cnt revs since version $ver, show given message.
# Or $id-unreleased to show given message for an unreleased plugin.
$knownRevs = readFromStdin();
#
# $repoMap of $id => repo
# To handle cases where artifactId from POM doesn't map directly
# to github repo name or directory name in svn. Set to 'skip' to skip item.
# Default for repo is $id-plugin for github and $id for svn.
$repoMap = readFromStdin();
#
# $reallyGithub of $id=>1
# For plugins that migrate to github but have not yet run a release there.
$reallyGithub = readFromStdin();
#
$prefix = isset($argv[1]) ? $argv[1] : '';
$issueUrl = 'http://issues.jenkins-ci.org/browse';
$svn = 'svn --non-interactive';
$svnBase = 'https://svn.jenkins-ci.org';
# Where to find all svn tags (a couple plugins use a subdir of /tags)
$svnTagDirs = array("$svnBase/tags",
                    "$svnBase/tags/global-build-stats",
                    "$svnBase/tags/scm-sync-configuration");
$fisheyeBase = 'http://fisheye.jenkins-ci.org';
$fisheyeUrl = array("$fisheyeBase/search/Jenkins/trunk/hudson/plugins/",
                    '?ql=select%20revisions%20from%20dir%20/trunk/hudson/plugins/',
                    '%20where%20date%20%3E=%20',
                    '%20group%20by%20changeset%20return%20csid,%20comment,%20author,%20path');
$monthMap = array('Jan'=>1, 'Feb'=>2, 'Mar'=>3, 'Apr'=>4, 'May'=>5, 'Jun'=>6,
                  'Jul'=>7, 'Aug'=>8, 'Sep'=>9, 'Oct'=>10, 'Nov'=>11, 'Dec'=>12);
date_default_timezone_set('America/Los_Angeles');

$seenGithubRepos = $seenJavanetDirs = $svnTagMap = array();

# 1. Load update-center.json
$updateCenter = json_decode(
        trim(file_get_contents('http://updates.jenkins-ci.org/update-center.json'),
             "updateCnr.os(); \t\n\r"));
if (!$updateCenter) mydie('** No data from update-center.json');

# 2. Load all tags from svn
$xml = xml_parser_create();
$svnTagDirs = implode(' ', $svnTagDirs);
xml_parse_into_struct($xml,
    `$svn ls --xml $svnTagDirs`, $xmlData, $xmlIndex);
xml_parser_free($xml);
if (!$xmlData) mydie('** Failed to get tags from svn');
foreach ($xmlIndex['NAME'] as $i) {
  $tag = $xmlData[$i]['value'];
  $rev = $xmlData[$i+2]['attributes']['REVISION'];
  # Split on last - to get plugin id and version#
  $p = ($i = strrpos($tag, '-')) === FALSE ? $tag : substr($tag, 0, $i);
  $v = $i === FALSE ? '' : substr($tag, $i + 1);
  # Build map of id->(version#,rev#), keeping latest rev# for each plugin
  if (!isset($svnTagMap[$p]) or $rev > $svnTagMap[$p][1]) $svnTagMap[$p] = array($v, $rev);
}

# 3. Process all released plugins
$data = array();
foreach ($updateCenter->plugins as $id => $p) {
  if ($prefix and !preg_match("/^$prefix/i", $id)) continue;
  $isGithub = strcasecmp(substr(isset($p->scm) ? $p->scm : '', -10), 'github.com') === 0
           || isset($reallyGithub[$id]);
  $repoName = isset($repoMap[$id]) ? $repoMap[$id] : ($isGithub ? "$id-plugin" : $id);
  if ($repoName==='skip') continue;
  # Check either github or svn for revisions since the latest release.
  if ($isGithub) {
    $seenGithubRepos[$repoName] = 1;
    $seenJavanetDirs[$id] = 1; # In case moved to github from svn
    list($ver, $revs, $url) = github($id, $repoName);
  } else {
    $seenJavanetDirs[$repoName] = 1;
    $seenGithubRepos[$repoName . '-plugin'] = 1; # Skip github mirror too
    list($ver, $revs, $url) = jenkinsSvn($id, $repoName, $p);
  }
  # Examine/count the revs-since-release and print resulting data.
  $data[] = processRevs($revs, $id, $p, $ver, $url);
}

# Skip github mirrors of svn dirs too
foreach ($repoMap as $key => $value) if ($value=='skip') $repoMap["$key-plugin"] = 'skip';

# 4. Get list of all directories under hudson/plugins in svn
#    and report any unreleased plugins
exec("$svn ls $svnBase/trunk/hudson/plugins", $plugins);
if (!$plugins) mydie('** Failed to get plugin list from svn');
foreach ($plugins as $p) {
  if ($prefix and !preg_match("/^$prefix/i", $p)) continue;
  if (substr($p, -1) == '/') {
    $p = substr($p, 0, -1);
    if (isset($repoMap[$p]) and $repoMap[$p] === 'skip') continue;
    if (!isset($seenJavanetDirs[$p])) {
      # TODO: get #revs and date range..
      $comment = knownRevs($p . '-unreleased');
      if (!$comment) $comment = 'unreleased';
      $data[] = "| [$p|$fisheyeBase/browse/Jenkins/trunk/hudson/plugins/$p] | | | $comment\n";
      $seenGithubRepos["$p-plugin"] = 1; # Don't also report github mirror as unreleased
    }
  }
}
# 5. Get list of all git repositories under github.com/jenkinsci
#    and report any unreleased plugins
for ($p = 1; TRUE; $p++) {
  $githubRepos = json_decode(
        file_get_contents('http://github.com/api/v2/json/repos/show/jenkinsci?page=' . $p));
  if (!$githubRepos) mydie('** Failed to get repo list from github');
  if (count($githubRepos->repositories) == 0) break;
  foreach ($githubRepos->repositories as $repo) {
    if ($prefix and !preg_match("/^$prefix/i", $repo->name)) continue;
    if (isset($repoMap[$repo->name]) and $repoMap[$repo->name] === 'skip') continue;
    if (!isset($seenGithubRepos[$repo->name])) {
      # TODO: get #revs and date range..
      $comment = knownRevs($repo->name . '-unreleased');
      if (!$comment) $comment = 'unreleased';
      $data[] = "| [$repo->name|http://github.com/jenkinsci/$repo->name] | | | $comment\n";
    }
  }
}

# 6. Group and print results
usort($data, function($a,$b){return strcasecmp(ltrim($a,'| ['),ltrim($b,'| ['));});
print "This is a report of unreleased changes in Jenkins' plugin repositories.\n"
    . "It is updated once per week.\n\nh3. Plugin Changes\n";
foreach ($data as $line) {
  if (strpos($line, 'CURRENT') === FALSE and strpos($line, 'unreleased') === FALSE) print $line;
}
print "\nh3. Unreleased Plugins\n";
foreach ($data as $line) {
  if (strpos($line, 'unreleased') !== FALSE) print $line;
}
print "\nh3. Current Plugins\n";
foreach ($data as $line) {
  if (strpos($line, 'CURRENT') !== FALSE) print $line;
}

# 7. Report any unused $knownRevs entries
foreach ($knownRevs as $key => $value) {
  if ($prefix and !preg_match("/^$prefix/i", $key)) continue;
  $data[] = "| Unused data in KnownRevs: | | | | $key | $value\n";
}
$time = time() - $time;
print "\nGenerated at: " . `date` . ' in ' . floor($time/60) . ' min ' . ($time%60) . " sec.\n";

### Helper methods

function knownRevs($key) {
  global $knownRevs;
  if (isset($knownRevs[$key])) {
    $result = $knownRevs[$key];
    unset($knownRevs[$key]);
  } else $result = FALSE;
  return $result;
}

function github($pluginId, $repoName) {
  # Get all tags in this repo, sort by version# and get highest
  list ($ver, $hash) = maxTag($pluginId, json_decode(
    file_get_contents("http://github.com/api/v2/json/repos/show/jenkinsci/$repoName/tags")));
  $revs = array();
  # URL to compare last release tag and master branch
  $url = "https://github.com/jenkinsci/$repoName/compare/$hash...master";
  # Fetch ".patch" version of this URL and split into revisions
  foreach (explode("\nFrom ", file_get_contents("$url.patch")) as $rev) {
    if (!preg_match(
          '|^Date: \w{3}, (\d+ \w+ \d+).*?\nSubject: \[PATCH[ \d/]*\]\s*(.*?)$|m', $rev, $match)) {
      mydie("** Failed to parse github revision for $pluginId: $rev");
    }
    $revs[] = array(dateFormat($match[1]), $match[2]);
  }
  return array($ver, $revs, $url);
}

function maxTag($pluginId, $json) {
  $pidLen = strlen($pluginId);
  $vers = array();
  foreach ($json->tags as $id => $hash) {
    if (preg_match("/^(?:$pluginId" . '-?)?([0-9._]+)$/', $id, $match))
      $vers[$match[1]] = $hash;
    else fwrite(STDERR, "** Skipped github tag: $pluginId - $id\n");
  }
  uksort($vers, 'version_compare');
  return each(array_reverse($vers));
}

function dateFormat($date) {
  global $monthMap;
  return preg_match('/^(\d+) (\w+) (\d+)$/', $date, $match)
    ? sprintf('%d-%02d-%02d', $match[3], $monthMap[$match[2]], $match[1]) : $date;
}

function jenkinsSvn($pluginId, $repoName, $pluginJson) {
  global $fisheyeUrl, $svnTagMap, $svn, $svnBase, $knownRevs;
  # URL for changes since last release
  $url = "$fisheyeUrl[0]$repoName$fisheyeUrl[1]$repoName$fisheyeUrl[2]"
    . $pluginJson->releaseTimestamp . $fisheyeUrl[3];
  $revs = array();
  # Get rev# when tag for last release was created
  list ($ver, $tagRev) =
    isset($svnTagMap[$pluginId]) ? $svnTagMap[$pluginId]
      : (isset($svnTagMap[$repoName]) ? $svnTagMap[$repoName] : $svnTagMap["$pluginId-plugin"]);
  if (!$tagRev) {
    $ver = '?';
    $key = "$pluginId-$ver-0";
    if (!isset($knownRevs[$key])) $knownRevs[$key] = '?'; # Don't show "CURRENT"
    fwrite(STDERR, "** Unable to find latest svn tag for $pluginId\n");
  } else {
    # Get revisions in trunk since last release
    $xml = xml_parser_create();
    xml_parse_into_struct($xml,
      `$svn log -r $tagRev:HEAD --xml $svnBase/trunk/hudson/plugins/$repoName`,
      $xmlData, $xmlIndex);
    xml_parser_free($xml);
    if (isset($xmlIndex['MSG'])) {
      foreach ($xmlIndex['MSG'] as $i) {
        $revs[] = array(substr($xmlData[$i-2/*DATE*/]['value'], 0, 10),
                        isset($xmlData[$i/*MSG*/]['value']) ? $xmlData[$i]['value'] : '');
      }
    } else {
      $key = "$pluginId-$ver-0";
      if (!isset($knownRevs[$key])) $knownRevs[$key] = '?'; # Don't show "CURRENT"
      fwrite(STDERR, "** Unable to find revisions for hudson/plugins/$repoName from r$tagRev\n");
    }
  }
  return array($ver, $revs, $url);
}

function processRevs($revs, $pluginId, $pluginJson, $ver, $url) {
  global $knownRevs, $issueUrl;
  $cnt = $l10n = 0;
  $firstDate = $result = FALSE;
  $fixed = array();
  foreach ($revs as $rev) {
    list ($date, $comment) = $rev;
    # Skip these commits from [maven-release]
    if (strpos($comment, 'prepare for next development iteration') !== FALSE
        or strncmp($comment, 'bumping up POM version', 22) === 0) {
      continue;
    }
    $cnt++;
    if (!$firstDate) $firstDate = $date;
    if (preg_match(
          '/^(integrated )?community[- ]contributed (localization|translation)/i', $comment)) {
      $l10n++;
    }
    for ($i = 0; preg_match('/FIXED ([A-Z]+-(\d+))/i',
                            $comment, $match, PREG_OFFSET_CAPTURE, $i);) {
      $fixed[] = '[' . $match[2][0] . "|$issueUrl/" . $match[1][0] . ']';
      $i = $match[2][1] + strlen($match[2][0]);
    }
  }

  $key = "$pluginId-$ver-$cnt";
  if (isset($knownRevs[$key])) { $result = $knownRevs[$key]; unset($knownRevs[$key]); }
  elseif (!$cnt) $result = 'CURRENT';
  else {
    if ($fixed) $result = 'Fixed: ' . implode(' ', $fixed);
    elseif ($l10n == $cnt) $result = '~CURRENT --';
    if ($l10n) $result .= ' l10n';
  }
  if ($ver and $ver !== $pluginJson->version)
    $result .= ' (_Version mismatch: json has ' . $pluginJson->version . '_)';

  $since = $cnt ? "[$cnt rev" . ($cnt > 1 ? 's' :'') . "|$url] | since" : '|';
  $p = !empty($pluginJson->wiki) ? "[$pluginId|$pluginJson->wiki]" : $pluginId;
  $today = today();
  $d = $firstDate ? ($firstDate==$date ? colorize($date, $today)
     : colorize($firstDate, $today) . ' to ' . colorize($date, $today)) : '';
  return "| $p | $since $ver | $d | $result\n";
}


function today() {
  $x = localtime();
  return $x[5] * 12 + $x[4] + $x[3]/31;
}

function ageMonths($date, $today) {
  $x = explode('-', $date);
  return $today - (($x[0] - 1900) * 12 + ($x[1] - 1) + $x[2]/31);
}

function colorize($date, $today) {
  $a = round(ageMonths($date,$today)/2);
  if ($a <= 0) return $date;
  if ($a > 5) $a = 5;
  $colors = array(0, '3', '6', '9', 'c', 'f');
  return '{color:#' . $colors[$a] . (9 - $a) . '6}' . $date . '{color}';
}

function readFromStdin() {
  $result = array();
  while (($line = fgets(STDIN)) !== FALSE and strncmp($line, '----', 4)) {
    if (($i = strpos($line, '#')) !== FALSE) $line = substr($line, 0, $i);
    $line = trim($line);
    if (!$line) continue;
    if (($i = strpos($line, '|')) > 0) {
      $result[rtrim(substr($line, 0, $i))] = ltrim(substr($line, $i + 1));
    } else {
      $result[$line] = 1;
    }
  }
  return $result;
}

function mydie($msg) {
  fwrite(STDERR, "$msg\n");
  exit(1);
}
?>
