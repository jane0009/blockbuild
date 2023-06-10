#!/usr/bin/env bash
set -e

if [ ! -d "./out" ]; then
  echo "Creating out dir..."
  mkdir out
else
  echo "Cleaning out dir..."
  rm -rf ./out/*
fi

hashes_txt_url=$(cat ./host_config.txt)"hashes.txt"
hashes_status_code=$(curl -s -o /dev/null -w "%{http_code}" $hashes_txt_url)

commits_txt_url=$(cat ./host_config.txt)"commits.txt"
commits_status_code=$(curl -s -o /dev/null -w "%{http_code}" $commits_txt_url)

previous_commits=""
previous_hashes=""

if [ "$hashes_status_code" -eq 200 ] && [ "$commits_status_code" -eq 200 ]; then
  echo "Fetching previous build info..."
  previous_hashes=$(curl -s $hashes_txt_url)
  previous_commits=$(curl -s $commits_txt_url)
fi

function build() {
  project_name=$1
  project_arg=$2

  if [ -z "$project_arg" ]; then
    project_arg="."
  fi

  build_dir="$project_arg/build/libs"
  out_dir="../../out/$project_name"

  cd ./libs/$project_name
  current_commit=$(git rev-parse HEAD)
  if [[ "$previous_commits" == *"$current_commit $project_name"* ]]; then
    echo "Skipping $project_name as commit hash is unchanged"
    cd ../..

    # Download all files from previous build so we don't delete them
    # Kind of wasteful?
    for hash_line in $previous_hashes; do
      if [[ "$hash_line" != *"$project_name"* ]]; then
        continue
      fi

      file=$(echo $hash_line | cut -d' ' -f2)
      # Remove up to the first slash
      file=${file#*/}

      outpath="./out/$file"

      echo "Downloading $file..."
      mkdir -p $(dirname $outpath)
      curl -s $(cat ./host_config.txt)$file -o $outpath
    done

    return
  fi

  echo "Building $project_name..."
  if [ -d "$build_dir" ]; then
    echo "Cleaning build artifacts..."
    rm -rf $build_dir
  fi

  ./gradlew build -p $project_arg

  echo "Copying build artifacts..."
  mkdir -p $out_dir
  cp $build_dir/*.jar $out_dir

  cd ../..
}

# read was doing some weird stuff so this'll work
build_config=`cat ./build_config.txt`
line_count=`echo "$build_config" | wc -l`
for (( i=1; i<=$line_count; i++ )); do
  line=`echo "$build_config" | sed -n "$i"p`
  if [ -z "$line" ]; then
    continue
  fi
  build $line
done

echo "Generating hash file..."
# Append to a temporary file and then move it, so it doesn't appear in the hash list itself
cd ./out
find . -type f -exec sha256sum {} \; > /tmp/hashes.txt
mv /tmp/hashes.txt ./hashes.txt
cd ..

echo "Generating commit file..."
for dir in ./libs/*; do
  if [ ! -d "$dir" ]; then
    continue
  fi

  cd $dir
  echo "$(git rev-parse HEAD) $(basename $dir)" >> ../../out/commits.txt
  cd ../..
done

if [ ! -z "$GPG_SECRET_KEY" ]; then
  echo "Signing hashes..."

  if [ ! -d "./gpg" ]; then
    echo "Creating GPG dir..."
    mkdir ./gpg
  else
    echo "Cleaning GPG dir..."
    rm -rf ./gpg/*
  fi

  export GNUPGHOME=`pwd`/gpg

  echo "Importing secret key..."
  echo "$GPG_SECRET_KEY" | base64 -d | gpg --import

  echo "Generating temporary key..."
  gpg_config="Key-Type: RSA
Key-Length: 4096
Name-Real: blockbuild
Name-Email: $GPG_TEMP_EMAIL
Expire-Date: 0
%no-protection
%commit"
  echo "$gpg_config" | gpg --batch --gen-key --armor

  gpg --list-keys

  function sign_file() {
    file=$1
    echo "Signing $file..."
    gpg --output $file.sig --sign --default-key "$GPG_SECRET_EMAIL" $file
    gpg --output $file.sig.tmp --sign --default-key "$GPG_TEMP_EMAIL" $file
  }

  sign_file ./out/hashes.txt
  sign_file ./out/commits.txt
fi
