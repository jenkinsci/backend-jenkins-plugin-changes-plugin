#!/usr/bin/python
# Script to update wiki page with latest generated report
import os
import sys
from xmlrpclib import Server

content = sys.stdin.read()
s = Server("https://wiki.jenkins-ci.org/rpc/xmlrpc")
token = s.confluence1.login("jenkins",
  open(os.environ['SECRET_DIR']+'/pwfile', 'r').readline().rstrip())
page = s.confluence1.getPage(token, "jenkins", "Unreleased Plugin Changes")
page["content"] = content
s.confluence1.storePage(token, page)

