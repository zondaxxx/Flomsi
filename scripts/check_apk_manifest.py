#!/usr/bin/env python3
"""Checks the sign-in return in a built APK's manifest: AppAuth's RedirectUriReceiverActivity
must carry a theme (it is an AppCompatActivity; without an AppCompat theme the app stops the
moment the sign-in page returns) and, when the build has a Google Android client, its scheme.

    aapt2 dump xmltree --file AndroidManifest.xml app-release.apk > manifest.txt
    python3 scripts/check_apk_manifest.py manifest.txt [--google]
"""
import re
import sys

text = open(sys.argv[1]).read()
# One block per component: from its element to the next component's.
blocks = re.split(r"\n(?=\s*E: (?:activity|activity-alias|service|receiver|provider)\b)", text)
redirect = [b for b in blocks if "RedirectUriReceiverActivity" in b]
if not redirect:
    sys.exit("no RedirectUriReceiverActivity in the manifest")
block = redirect[0]
print(block)
if "android:theme" not in block:
    sys.exit("RedirectUriReceiverActivity has no theme: the app would stop on returning from sign-in")
if "--google" in sys.argv and "com.googleusercontent.apps." not in block:
    sys.exit("RedirectUriReceiverActivity has no Google redirect scheme")
print("sign-in return: ok")
