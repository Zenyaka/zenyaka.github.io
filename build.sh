#!/bin/bash
git stash
git checkout master
git reset --hard dev

zola build

mv public/* .
rm -rf config.toml content sass static themes templaes
# echo "atsuzaki.com" >> CNAME # Edit and Reenable if we're using a domain in the future
git add -f .
git commit -m "Build"

git push -f origin master

# Cleanup
git checkout dev
git clean -f -d
git stash pop
