#!/bin/bash
git stash
git checkout master
git reset --hard dev

zola build

mv public/* .
rm -rf config.toml content sass static themes templaes
echo "zenyaka.dev" >> CNAME
git add -f .
git commit -m "Build"

git push -f origin master

# Cleanup
git checkout dev
git clean -f -d
git stash pop
