# shellcheck shell=bash disable=SC2034 # The browser command uses these.
# Configuration of the browser command (~/.local/bin/browser).
# The command sources this file with bash 3.2.

# The driver to use when the user did not run "browser use <driver>".
BROWSER_DEFAULT=vivaldi

# The spaces, in order. In Vivaldi, the order is the order of the
# workspaces: "browser space Zaid" sends "Switch to workspace 3".
BROWSER_SPACES="Work Research Zaid YouTube Study"

# The named tabs for "browser tab <name>". One tab on each line:
#   <name>[@<driver>]|<space>|<URL prefix>
# A driver finds the tab whose URL starts with the prefix. A line with
# @<driver> replaces the line without it, for that driver only.
# Google numbers the accounts in the order of sign-in. In Vivaldi, the
# personal account is 0 and the work account is 1. A Google URL without an
# account number opens account 0, so give the number for each Google tab.
# Do not write a company domain here. This repository is public.
BROWSER_TABS='gchat|Work|https://chat.google.com/u/1
gmail|Zaid|https://mail.google.com/mail/u/0
gmail-work|Work|https://mail.google.com/mail/u/1'

# The Pinboard tag of each space, for "browser bookmarks" (Hyper -). One
# space on each line: <space>|<Pinboard tag>
BROWSER_BOOKMARK_TAGS='Work|browser/work
Research|browser/research
Zaid|browser/personal
YouTube|browser/youtube
Study|browser/study'

# The bookmark cache of the Pin Plus Alfred workflow. Pin Plus keeps it up
# to date with the Pinboard token, so "browser bookmarks" needs no token.
BROWSER_BOOKMARKS="$HOME/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.vitorgalvao.alfred.pinplus/all_bookmarks.json"
