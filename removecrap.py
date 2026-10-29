#!/usr/bin/env python3

import os
import argparse
import subprocess
import re
import platform
import sys
import json

# Characters to remove
unwanted_chars = [  '\''    ,       #   single apostrophe
                    '\"'    ,       #   quotation mark
                    '('     ,       #   open parentheses
                    ')'     ,       #   close parentheses
                    ','     ,       #   comma
                    '!'     ,       #   exclamation point
                    '['     ,       #   open bracket
                    ']'     ,       #   close bracket
                    '`'     ,       #   tilde
                    ':'     ,       #   colon
                    ';'     ]       #   semicolon

# Separator characters that should never appear at the start or end of the name,
# and should never appear doubled up (e.g. "..", ".-.", "--")
separator_chars = '.-_ '

# Crappy strings of characters often added to filenames by rippers as branding
unwanted_strings = [
    "[Judas]","Multi-Subs","(Weekly)","CAKES","MeGusta","Rapta","ELiTE","NeoNoir","ETHEL","www.UIndex.org",
    "[EZTVx.to]","FENiX"
]


def debug_rename(args):
    # path, file = os.path.split(filepath)
    # crap_to_remove = re.findall(r'[^\x00-\x7F]', filepath) + unwanted_chars
    # print(f"unwanted chars found in {filepath}: {crap_to_remove}")
    # new_filename = ''.join(c for c in new_filename if c not in crap_to_remove)
    print(args)
    print(args.directory)
    print(args.unwanted_string)

def tidy_separators(name):
    """
    Collapses messy runs of separators left behind after removing strings/characters,
    then strips separators off both ends.
        ".Show.-.01..1080p.-" -> "Show-01.1080p"
    """
    name = re.sub(r'[._ ]*-[-._ ]*', '-', name)   # any run containing a dash -> single "-"
    name = re.sub(r'[._ ]{2,}', '.', name)         # any other run of separators -> single "."
    return name.strip(separator_chars)

def clean_filename(filepath, dry_run=False):
    """
    Renames the file at `filepath` by removing unwanted strings, unwanted characters,
    and non-ASCII characters, and making sure the name doesn't start or end with
    a separator character.
    """

    path, file = os.path.split(filepath)

    # Work on the name and extension separately so ".mkv" etc. stays intact
    stem, ext = os.path.splitext(file)

    
    # Matches any character that is NOT within the ASCII range
    crap_to_remove = re.findall(r'[^\x00-\x7F]', filepath) + unwanted_chars
    if crap_to_remove:
        print(f"Unwanted chars FOUND in {filepath}: {crap_to_remove}")

    
    # # First remove unwanted strings
    new_stem = stem
    for x in unwanted_strings:
        new_stem = new_stem.replace(x, '')

    # # Next remove any lingering unwanted characters
    # new_stem = new_stem.replace(' ','.')
    # new_stem = new_stem.replace('.-.','-')
    # new_stem = new_stem.replace('.-','-')
    # new_stem = new_stem.replace('..','.')
    new_stem = ''.join(c for c in new_stem if c not in crap_to_remove)

    # Spaces become dots, then clean up separators in the middle and at both ends
    new_stem = new_stem.replace(' ', '.')
    new_stem = tidy_separators(new_stem)


    if not new_stem:
        print(f"Skipping {file}: nothing left of the name after cleaning")
        return

    # # Full path for new file name
    new_filename = new_stem + ext.strip()
    new_filepath = os.path.join(path, new_filename)

    if new_filepath == filepath:
        print("No changes made.")
        return
 
    if os.path.exists(new_filepath):
        print(f"Skipping {file}: {new_filename} already exists")
        return
 
    if dry_run:
        print(f"Would rename: {file} -> {new_filename}")
    else:
        os.rename(filepath, new_filepath)
        print(f"Renamed: {file} -> {new_filename}")


def main(directory, extra_strings=None, dry_run=False):
    print(f"Working in {directory}...")
    if extra_strings:
        unwanted_strings.extend(extra_strings)
    for file in os.listdir(directory):
        full_path = os.path.join(directory, file)
        if os.path.isdir(full_path):
            print(f"Skipping directory {file}")
            continue
        print(f"Checking {file}...")
        clean_filename(full_path, dry_run=dry_run)
 
 
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Renames files in given directory by removing characters that are non linux-friendly")
    parser.add_argument('-d', '--directory', type=str, action='store', dest='directory', default=os.getcwd(),
                        help='the parent directory for the script to run in')
    parser.add_argument('-u', '--unwanted-string', dest='unwanted_string', action='append',
                        help='a string to remove from the filename (repeat -u for more than one)')
    parser.add_argument('-n', '--dry-run', action='store_true',
                        help='show what would be renamed without renaming anything')
 
    args = parser.parse_args()
    main(args.directory, extra_strings=args.unwanted_string, dry_run=args.dry_run)












# crapchars = [
#     " ",
#     "(",
#     ")"
# ]
# # crapchars = [
# #     [" ","_"],
# #     ["(",""],
# #     [")",""]
# # ]

# name = ""
# tmp = "blah flahdy (glah )"
# for c in tmp:
#     print("current letter: " + c)
#     if c not in ([ x for x in crapchars]):
#         name = name + c
#     else:
#         print("found a crap char: " + c)
#         if " " in c:
#             name = name + "_"
# print(name)
        