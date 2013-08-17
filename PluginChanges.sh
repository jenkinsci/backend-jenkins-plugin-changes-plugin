#!/bin/sh
export SECRET_DIR=`pwd`
python -d PluginChangesReport.py <RepoInfo.txt > report.txt
