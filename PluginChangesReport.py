#!/usr/bin/python
# Script to generate report of unreleased plugin changes in Jenkins' plugin repositories.
# @author Alan Harder
#
from distutils import version
import json
import os
import re
from StringIO import StringIO
import sys
from time import localtime, sleep, time
from datetime import datetime
from urllib2 import urlopen
from xml.etree import ElementTree

start_time = time()

# $knownRevs of $id-$ver-$cnt => text
# To display a message in the report regarding the state of a plugin.
# Usually to show a message like "~CURRENT -- pom,test" if a plugin's
# changes since the last release don't actually change anything in a
# release (such as pom changes or unit tests).
# For plugin $id with $cnt revs since version $ver, show given message.
# Or $id-unreleased to show given message for an unreleased plugin.
knownRevs = {}

# $repoMap of $id => repo
# To handle cases where artifactId from POM doesn't map directly
# to github repo name or directory name in svn. Set to 'skip' to skip item.
# Default for repo is $id-plugin for github and $id for svn.
repoMap = {}

# $tagMap of $id => tagBase | [pluginSubDir or VER_OK] [ | suffix ]
# Assists in finding latest version of a plugin when the tags are not
# simple "pluginId-version" due to non-standard tags or use of a parent pom.
# Maps pluginId to the base name used for tags and how to find the release
# version; the latter can be "VER_OK" which means the version in the tag
# matches the release version; if the parent pom has different version
# numbers than the plugin release, specify the subdirectory in the source
# where the plugin resides and the version will be looked up in the pom.
# Optionally add |suffix to specify a regex to allow after the version#.
tagMap = {}

# $reallyGithub of $id=>1
# For plugins that migrate to github but have not yet run a release there.
reallyGithub = {}

issueUrl = 'http://issues.jenkins-ci.org/browse'
svn = 'svn --non-interactive'
svnBase = 'https://svn.jenkins-ci.org'
# Where to find all svn tags (a couple plugins use a subdir of /tags)
svnTagDirs = [ svnBase + '/tags',
               svnBase + '/tags/global-build-stats',
               svnBase + '/tags/scm-sync-configuration' ]
fisheyeBase = 'http://fisheye.jenkins-ci.org'
fisheyeUrl = [ fisheyeBase + '/search/Jenkins/trunk/hudson/plugins/',
               '?ql=select%20revisions%20from%20dir%20/trunk/hudson/plugins/',
               '%20where%20date%20%3E=%20',
               '%20group%20by%20changeset%20return%20csid,%20comment,%20author,%20path' ]
monthMap = { 'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
             'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12 }
svnTagMap = {}

def main():
  prefix = sys.argv[1] if len(sys.argv) > 1 else ''

  # 1. Load update-center.json
  updateCenter = json.load(StringIO(
        urlopen('http://updates.jenkins-ci.org/update-center.json')
            .read().strip('updateCnr.os(); \t\n\r')))

  # 2. Load all tags from svn
  xml = ElementTree.XML(
        os.popen('%s ls --xml %s' % (svn, ' '.join(svnTagDirs))).read())
  for entry in xml.findall('list/entry'):
    tag = entry.find('name').text
    rev = int(entry.find('commit').get('revision'))
    if '-' in tag:
      # Split on last - to get plugin id and version#
      (p, v) = tag.rsplit('-', 1)
      # Build map of id->(version#,rev#), keeping latest rev# for each plugin
      if p not in svnTagMap or rev > svnTagMap[p][1]: svnTagMap[p] = (v, rev)

  # 3. Process all released plugins
  data = []
  seenGithubRepos = {}
  seenJavanetDirs = {}
  for (id, p) in updateCenter['plugins'].items():
    if not id.startswith(prefix): continue
    if 'scm' not in p: print >> sys.stderr, '** Missing scm info for', id
    isGithub = ('scm' in p and p['scm'][-10:].lower() == 'github.com'
                or id in reallyGithub)
    # By default $id matches dir name in svn, and "$id-plugin" is repo name in github:
    repoName = (repoMap[id] if id in repoMap
                else (id + '-plugin' if isGithub and id[-7:] != '-plugin' else id))
    if repoName == 'skip': continue
    # Check either github or svn for revisions since the latest release.
    if isGithub:
      seenGithubRepos[repoName] = 1
      seenJavanetDirs[id] = 1  # In case moved to github from svn
      (ver, revs, url) = github(id, repoName)
    else:
      seenJavanetDirs[repoName] = 1
      seenGithubRepos[repoName + '-plugin'] = 1  # Skip github mirror too
      (ver, revs, url) = jenkinsSvn(id, repoName, p)
    # Examine/count the revs-since-release and add to data.
    data.append(processRevs(revs, id, p, ver, url))

  # Skip github mirrors of svn dirs too
  for (key, value) in repoMap.items():
    if value == 'skip': repoMap[key + '-plugin'] = 'skip'

  # 4. Get list of all directories under hudson/plugins in svn
  #    and report any unreleased plugins
  for p in [ x.rstrip() for x in
             os.popen('%s ls %s/trunk/hudson/plugins' % (svn, svnBase)) ]:
    if not p.startswith(prefix): continue
    if p[-1] == '/':
      p = p[:-1]
      if p in repoMap and repoMap[p] == 'skip': continue
      if p not in seenJavanetDirs:
        # TODO: get #revs and date range..
        comment = getKnownRevs(p + '-unreleased')
        if not comment: comment = 'unreleased'
        data.append('| [%s|%s/browse/Jenkins/trunk/hudson/plugins/%s] | | | %s'
                    % (p, fisheyeBase, p, comment))
        seenGithubRepos[p + '-plugin'] = 1  # Don't also report github mirror as unreleased

  # 5. Get list of all git repositories under github.com/jenkinsci
  #    and report any unreleased plugins
  page = 1
  while True:
    githubRepos = json.load(
        urlopen('https://api.github.com/orgs/jenkinsci/repos?page=%s&per_page=100' % page))
    if len(githubRepos) == 0: break
    for repoName in [ repo['name'] for repo in githubRepos ]:
      if not repoName.startswith(prefix): continue
      if repoName in repoMap and repoMap[repoName] == 'skip': continue
      if repoName not in seenGithubRepos:
        # TODO: get #revs and date range..
        comment = getKnownRevs(repoName + '-unreleased')
        if not comment: comment = 'unreleased'
        data.append('| [%s|http://github.com/jenkinsci/%s] | | | %s'
                    % (repoName, repoName, comment))
    page += 1

  # 6. Group and print results
  data = sorted(data, key=lambda s: s.lstrip('| [').lower())
  print('This is a report of unreleased changes in Jenkins\' plugin repositories.\n'
        'It is updated once per week.\n\nh3. Plugin Changes')
  for line in data:
    if not 'CURRENT' in line and not 'unreleased' in line: print line
  print '\nh3. Unreleased Plugins'
  for line in data:
    if 'unreleased' in line: print line
  print '\nh3. Current Plugins'
  for line in data:
    if 'CURRENT' in line: print line

  # 7. Report any unused $knownRevs entries
  for (key, value) in knownRevs.items():
    if not key.startswith(prefix): continue
    print '| Unused data | in | KnownRevs: | %s | %s' % (key, value);

  duration = int(time() - start_time)
  print('\nGenerated at: %s in %d min %d sec\n'
        % (os.popen('date').read(), duration/60, duration%60))

### Helper methods

def readFromStdin():
  result = {}
  for line in sys.stdin:
    if line.startswith('----'): break
    if '#' in line: line = line[:line.index('#')]
    line = line.strip()
    if not line: continue
    if '|' in line:
      result[line[:line.index('|')].rstrip()] = line[line.index('|')+1:].lstrip()
    else:
      result[line] = 1
  return result

def getUrl(url):
  sleep(3)  # Don't hit github too fast
  try:
    return urlopen(url)
  except IOError as e:
    # Retry once
    sleep(3)
    print >> sys.stderr, '**', e, '\n** Retry', url
    try: return urlopen(url)
    except IOError as e:
      print >> sys.stderr, '**', e
      return False

def getJson(url):
  s = getUrl(url)
  return json.load(s) if s else False

def getKnownRevs(key):
  if key in knownRevs:
    result = knownRevs[key]
    del knownRevs[key]
  else: result = False
  return result;

def github(pluginId, repoName):
  # Prepend github account "jenkinsci" if another account not specified
  if '/' not in repoName: repoName = 'jenkinsci/' + repoName
  # Get all tags in this repo, sort by version# and get highest
  (ver, tag) = maxTag(pluginId, repoName, getJson(
        'https://api.github.com/repos/%s/tags' % repoName))
  revs = getRevs(repoName, tag)
  # URL to compare last release tag and master branch
  url = 'https://github.com/%s/compare/%s...master' % (repoName, tag['name'])
  return (ver, revs, url)

def getRevs(repoName, tag):
  commits = getJson('https://api.github.com/repos/%s/commits' % repoName)
  revs = []
  if not commits: return revs
  for commit in commits:
    revs.append( (dateFormat2(commit['commit']['author']['date']), commit['commit']['message']) )
    if commit['sha'] == tag['commit']['sha']:
      break
  return revs;

def maxTag(pluginId, repoName, json):
  if not json: return ('', '')
  vers = {}
  rx = re.compile('^(?:%s-?)?([0-9._]+)$' % pluginId)
  for tagentry in json:
    tag = tagentry['name']
    match = rx.match(tag)
    if match:
      vers[match.group(1)] = tagentry
      continue
    elif pluginId in tagMap:
      entry = tagMap[pluginId].split('|')
      if len(entry) < 3: entry.append('')
      match = re.match('^(?:%s-?)?([0-9._]+%s)$' % (entry[0], entry[2]), tag)
      if match:
        ver = lookupVersion(entry[1], match.group(1), repoName, tag)
        if ver:
          vers[ver] = tagentry
          continue
    print >> sys.stderr, '** Skipped github tag: %s - %s' % (pluginId, tag)
  if not vers: return ('', '')
  key = max(vers.keys(), key=lambda v: version.LooseVersion(v.replace('_', '.')))
  return (key, vers[key])

def lookupVersion(pluginSubDir, tagVersion, repoName, tag):
  if pluginSubDir == 'VER_OK': return tagVersion
  xml = ElementTree.XML(
      urlopen('https://github.com/%s/raw/%s/%s/pom.xml'
              % (repoName, tag, pluginSubDir)).read())
  # Need to account for xmlns in find:
  return xml.find('{%s}version' % xml.tag[1:xml.tag.index('}')]).text

def dateFormat(date):
  match = re.match('^(\d+) (\w+) (\d+)$', date)
  return ('%s-%02d-%02d' % (match.group(3), monthMap[match.group(2)], int(match.group(1)))
          if match else date)

def dateFormat2(date):
  dt=datetime.strptime(date, '%Y-%m-%dT%H:%M:%SZ')
  return dt.strftime('%Y-%m-%d')

def jenkinsSvn(pluginId, repoName, pluginJson):
  # URL for changes since last release
  url = (fisheyeUrl[0] + repoName + fisheyeUrl[1] + repoName + fisheyeUrl[2]
         + pluginJson['releaseTimestamp'] + fisheyeUrl[3])
  revs = []
  # Get rev# when tag for last release was created
  (ver, tagRev) = (svnTagMap[pluginId] if pluginId in svnTagMap else
      (svnTagMap[repoName] if repoName in svnTagMap else svnTagMap[pluginId + '-plugin']))
  if not tagRev:
    ver = '?'
    key = '%s-%s-0' % (pluginId, ver)
    if key not in knownRevs: knownRevs[key] = '?'  # Don't show "CURRENT"
    print >> sys.stderr, '** Unable to find latest svn tag for %s' % pluginId
  else:
    # Get revisions in trunk since last release
    xml = ElementTree.XML(
        os.popen('%s log -r %s:HEAD --xml %s/trunk/hudson/plugins/%s'
                 % (svn, tagRev, svnBase, repoName)).read())
    log = xml.findall('logentry')
    if log:
      for entry in log:
        msg = entry.find('msg').text
        revs.append( (entry.find('date').text[:10],
                      msg if msg is not None else '') )
    else:
      key = '%s-%s-0' % (pluginId, ver)
      if key not in knownRevs: knownRevs[key] = '?'  # Don't show "CURRENT"
      print >> sys.stderr, ('** Unable to find revisions for hudson/plugins/%s from r%s'
                            % (repoName, tagRev))
  return (ver, revs, url)

def processRevs(revs, pluginId, pluginJson, ver, url):
  cnt = 0
  l10n = 0
  l10n_rx = re.compile(
      '^(integrated )?community[- ]contributed (localization|translation)', re.IGNORECASE)
  issue_rx = re.compile('FIX[EDS]* [A-Z]+-(\d+)', re.IGNORECASE)
  firstDate = False
  result = ''
  fixed = []
  for (date, comment) in revs:
    # Skip these commits from [maven-release]
    if ('prepare for next development' in comment
        or comment.startswith('bumping up POM version')):
      continue
    cnt += 1
    if not firstDate: firstDate = date
    if l10n_rx.match(comment): l10n += 1
    for match in issue_rx.findall(comment):
      fixed.append('[%s|%s/JENKINS-%s]' % (match, issueUrl, match))

  key = '%s-%s-%d' % (pluginId, ver, cnt)
  if key in knownRevs:
    result = knownRevs[key]
    del knownRevs[key]
  elif not cnt: result = 'CURRENT'
  else:
    if fixed: result = 'Fixed: ' + ' '.join(fixed)
    elif l10n == cnt: result = '~CURRENT --'
    if l10n: result += ' l10n'
  if ver and ver != pluginJson['version']:
    result += ' (_Version mismatch: json has %s_)' % pluginJson['version']

  since = '[%d rev%s|%s] | since' % (cnt, 's' if cnt > 1 else '', url) if cnt else '|'
  p = '[%s|%s]' % (pluginId, pluginJson['wiki']) if 'wiki' in pluginJson else pluginId
  today = getToday()
  if firstDate:
    d = (colorize(date, today) if firstDate == date else
         colorize(firstDate, today) + ' to ' + colorize(date, today))
  else: d = ''
  return '| %s | %s %s | %s | %s' % (p, since, ver, d, result)

def getToday():
  t = localtime()
  return (t.tm_year - 1900) * 12 + t.tm_mon + t.tm_mday/31.0;

def ageMonths(date, today):
  x = date.split('-')
  return today - ((int(x[0]) - 1900) * 12 + int(x[1]) + int(x[2])/31.0)

def colorize(date, today):
  a = int(round(ageMonths(date, today)/2.0))
  if a <= 0: return date
  if a > 5: a = 5
  colors = [ 0, '3', '6', '9', 'c', 'f' ]
  return '{color:#%s%d6}%s{color}' % (colors[a], 9 - a, date)

knownRevs = readFromStdin()
repoMap = readFromStdin()
tagMap = readFromStdin()
reallyGithub = readFromStdin()

main()
