#!/usr/bin/python
# Script to update wiki page with latest generated report
import os
import sys
from xmlrpclib import Server

content = sys.stdin.read()
s = Server("http://wiki.hudson-ci.org/rpc/xmlrpc")
token = s.confluence1.login("hudson", open(os.environ['PWFILE'], 'r').readline().rstrip())
page = s.confluence1.getPage(token, "hudson", "Unreleased Plugin Changes")
page["content"] = content
s.confluence1.storePage(token, page)

