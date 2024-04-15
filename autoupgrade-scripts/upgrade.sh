#!/bin/bash

source .env

# Working directories
export RELEASE_DIRECTORY=./releases
export DUMP_DIRECTORY=./dumps
export LOGS_DIRECTORY=./logs

mkdir -p "$RELEASE_DIRECTORY"
mkdir -p "$DUMP_DIRECTORY"
mkdir -p "$LOGS_DIRECTORY"

# Remove previous executions
rm -rf ./logs/*
rm -rf ./releases/*
rm -rf ./dumps/*

docker compose down --volumes --remove-orphans

if dpkg --compare-versions "$BASE_VERSION" ge 9.0.0; then
  export PRESTASHOP_WORK_BASE_VERSION=8.1-fpm
  docker compose build work-base
else
  docker compose build work-base
fi

# Install Prestashop. Stop process on error
install() {
  echo "--- Installation of v$1 ---"
  db_version="${1//./}"
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$1" work-base php install/index_cli.php \
    --step=all --db_server=mysql:3306 --db_name=presta_"$db_version" --db_DOCKER_USER_ID=root --db_password="$MYSQL_ROOT_PASSWORD" --prefix=ps_ --db_clear=1 \
    --domain=localhost:8002 --firstname="Marc" --lastname="Beier" \
    --password=Toto123! --email=demo@prestashop.com --language=fr --country=fr \
    --newsletter=0 --send_email=0 --ssl=0 >"$LOGS_DIRECTORY"/"$1"_install

    if grep -qiE 'fatal|error' "$LOGS_DIRECTORY"/"$1"_install; then
        echo "Docker command failed. See $LOGS_DIRECTORY/$1_install. Stopping the script (v$1)."
        exit 1
    fi

  echo "--- Installation of v$1 done ---"
}

# Download ZIP and XML for upgrade. This will place them in the folder "$RELEASE_DIRECTORY"/"$BASE_VERSION"/admin/autoupgrade/download.
# The contents of the ZIP are also copied to the releases folder under the version name
download_release_and_xml() {
  echo "--- Download v$1 Prestashop release and xml MD5 ---"
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base \
    curl --fail -L https://github.com/PrestaShop/PrestaShop/releases/download/"$1"/prestashop_"$1".zip -o admin/autoupgrade/download/prestashop_"$1".zip

  if [ ! $? -eq 0 ]; then
    echo "Download v$1 Prestashop release zip fail, see" https://github.com/PrestaShop/PrestaShop/releases/download/"$1"/prestashop_"$1".zip
    exit 1
  fi

  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base \
    curl --fail -L https://api.prestashop.com/xml/md5/"$1".xml -o admin/autoupgrade/download/prestashop_"$1".xml

  if [ ! $? -eq 0 ]; then
    echo "Download v$1 Prestashop release xml fail, see" https://api.prestashop.com/xml/md5/"$1".xml
    exit 1
  fi

  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY" work-base /bin/sh -c \
    "cp $BASE_VERSION/admin/autoupgrade/download/prestashop_"$1".zip .
    unzip -o prestashop_$1.zip -d $1 >/dev/null;
    rm prestashop_$1.zip;
    cd $1 || exit;
    unzip -o prestashop.zip >/dev/null;
    rm prestashop.zip;
    mkdir admin/autoupgrade/download;"

  if [ ! $? -eq 0 ]; then
    echo "Unzip v$1 Prestashop release fail"
    exit 1
  fi

  echo "--- Download v$1 Prestashop release and xml MD5 ---"
}

# Clean modules, for development purpose only
clean_modules() {
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base /bin/sh -c \
    "cp -r modules/autoupgrade .;
    rm -rf modules/*;
    mv autoupgrade modules/;"
}

upgrade() {
  if [[ "$CLEAN_MODULES_BEFORE_UPGRADE" == true ]]; then
    clean_modules
  fi

  download_release_and_xml "$2"
  upgrade_process "$1" "$2"
}

upgrade_experimental() {
  if [[ "$CLEAN_MODULES_BEFORE_UPGRADE" == true ]]; then
      clean_modules
  fi

  build_dev_release "$2"
  upgrade_process "$1" "$2"
}

upgrade_process() {
  echo "--- Upgrade from v$1 to v$2 ---"

  if dpkg --compare-versions "$2" ge 9.0.0; then
    export PRESTASHOP_WORK_BASE_VERSION=8.1-fpm
    docker compose build work-base
  fi

  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base \
    sh -c "echo '{\"channel\":\"archive\",\"archive_prestashop\":\"prestashop_$2.zip\",\"archive_num\":\"$2\", \"archive_xml\":\"prestashop_$2.xml\", \"PS_AUTOUP_CHANGE_DEFAULT_THEME\":\"0\", \"skip_backup\": \"1\"}' > modules/autoupgrade/config.json"

  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base \
    php modules/autoupgrade/cli-updateconfig.php --from=modules/autoupgrade/config.json --dir=admin >"$LOGS_DIRECTORY"/"$2"_upgrade

  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base \
    php modules/autoupgrade/tests/testCliProcess.php modules/autoupgrade/cli-upgrade.php --dir="admin" --action="compareReleases" >>"$LOGS_DIRECTORY"/"$2"_upgrade

  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$BASE_VERSION" work-base \
    php modules/autoupgrade/tests/testCliProcess.php modules/autoupgrade/cli-upgrade.php --dir="admin" >>"$LOGS_DIRECTORY"/"$2"_upgrade

  if [ ! $? -eq 0 ]; then
    echo "Upgrade from v$1 to v$2 fail, see" "$LOGS_DIRECTORY"/"$2"_upgrade
    exit 1
  fi

  echo "--- Upgrade from v$1 to v$2 done ---"
}

# Download ZIP for initial install.
# The contents of the ZIP are copied to the releases folder under the version name
download_release() {
  echo "--- Download v$1 Prestashop release ---"
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ work-base /bin/sh -c \
    "cd $RELEASE_DIRECTORY || exit
     curl --fail -LO https://github.com/PrestaShop/PrestaShop/releases/download/$1/prestashop_$1.zip;
     unzip -o prestashop_$1.zip -d $1 >/dev/null;
     rm prestashop_$1.zip;
     cd $1 || exit;
     unzip -o prestashop.zip >/dev/null;
     rm prestashop.zip;
     mkdir admin/autoupgrade/download;"

  if [ ! $? -eq 0 ]; then
    echo "Download v$1 Prestashop release zip fail, see" https://github.com/PrestaShop/PrestaShop/releases/download/"$1"/prestashop_"$1".zip
    exit 1
  fi

  echo "--- Download v$1 Prestashop release done ---"
  echo ""
}

# Download and build development branch.
# The contents of the ZIP are copied to the releases folder under the version name
build_dev_release() {
  echo "--- Download v$1 Prestashop and build release ---"
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/releases work-base /bin/sh -c \
    "git clone https://github.com/PrestaShop/PrestaShop.git;
    cd PrestaShop;
    git checkout $UPGRADE_DEVELOPMENT_BRANCH;
    php tools/build/CreateRelease.php --version=$1 --destination-dir=$1;
    cp $1/prestashop_$1.zip ../;
    mv $1/prestashop_$1.zip /var/www/html/$RELEASE_DIRECTORY/$BASE_VERSION/admin/autoupgrade/download;
    mv $1/prestashop_$1.xml /var/www/html/$RELEASE_DIRECTORY/$BASE_VERSION/admin/autoupgrade/download;
    cd ..;
    rm -rf PrestaShop;
    unzip -o prestashop_$1.zip -d $1 >/dev/null;
    rm prestashop_$1.zip;
    cd $1 || exit;
    unzip -o prestashop.zip >/dev/null;
    rm prestashop.zip;"

  if [ ! $? -eq 0 ]; then
    echo "Build release v$1 fail"
    exit 1
  fi

  echo "--- Download v$1 Prestashop and build release done ---"
  echo ""
}

# Download autoupgrade module
install_module() {
  echo "--- Install autoupgrade module (dev version) --- "
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$RELEASE_DIRECTORY"/"$1" composer /bin/sh -c \
    "cd modules;
     git clone $AUTOUPGRADE_GIT_REPO;
     cd autoupgrade;
     git checkout $AUTOUPGRADE_GIT_BRANCH;
     composer install;"

  if [ ! $? -eq 0 ]; then
    echo "Install autoupgrade module fail"
    exit 1
  fi

  echo "--- Install autoupgrade module (dev version) done ---"
  echo ""
}

dump_DB() {
  echo "--- Create dump for $1 ---"
  version="${1//./}"
   if [[ -n "$2" ]]; then
      docker compose run --rm mysql sh -c "exec mysqldump -hmysql -uroot --no-data -p$MYSQL_ROOT_PASSWORD presta_$version" >"$DUMP_DIRECTORY"/"$1"_to_"$2"_dump_.sql
   else
      docker compose run --rm mysql sh -c "exec mysqldump -hmysql -uroot --no-data -p$MYSQL_ROOT_PASSWORD presta_$version" >"$DUMP_DIRECTORY"/"$1"_dump_.sql
   fi
  echo "--- Create dump for $1 done ---"
  echo ""
}

create_DB_schema() {
  echo "--- Create database schema for $1 ---"
  version="${1//./}"
  docker compose run --rm mysql mysql -hmysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE presta_$version;"
  echo "--- Create database schema for $1 done ---"
  echo ""
}

create_DB_diff() {
  echo "--- Create database diff between $BASE_VERSION and $1 ---"
  docker compose run -u "$DOCKER_USER_ID" --rm -v ./:/var/www/html/ -w /var/www/html/"$DUMP_DIRECTORY" composer \
     git diff "$BASE_VERSION"_to_"$1"_dump_.sql "$1"_dump_.sql > "$DUMP_DIRECTORY"/diff_"$BASE_VERSION"_upgrated_"$1".txt
  echo "--- Create database diff between $BASE_VERSION and $1 done ---"
  echo ""
}

docker compose up -d mysql
download_release "$BASE_VERSION"
sleep 10
create_DB_schema "$BASE_VERSION"
install "$BASE_VERSION"
install_module "$BASE_VERSION"

if [[ "$RECURSIVE_MODE" == true ]]; then
  previousTag=$BASE_VERSION

  for tag in $(git ls-remote --tags --refs git@github.com:PrestaShop/PrestaShop.git | awk -F/ '{print $NF}'); do
    if dpkg --compare-versions "$tag" gt "$BASE_VERSION" && \
       dpkg --compare-versions "$tag" le "$UPGRADE_VERSION" && \
       [[ "$tag" != *'beta'* && "$tag" != *'rc'* ]]; then

        upgrade "$previousTag" "$tag"
        previousTag=$tag
    fi
  done

  if [[ "$UPGRADE_DEVELOPMENT_VERSION" == true && "$previousTag" != "$UPGRADE_VERSION" ]]; then
    upgrade_experimental "$previousTag" "$UPGRADE_VERSION"
  else
    echo "Warning: The BUILD_DEVELOP tag has not been taken into account, the target version is already available in releases and the upgrade has been done"
  fi
else
  if [[ "$UPGRADE_DEVELOPMENT_VERSION" == true ]]; then
      upgrade_experimental "$BASE_VERSION" "$UPGRADE_VERSION"
    else
      upgrade "$BASE_VERSION" "$UPGRADE_VERSION"
  fi
fi

if [[ "$CREATE_AND_COMPARE_DUMP_WITH_FRESH_INSTALL" == true ]]; then
  dump_DB "$BASE_VERSION" "$UPGRADE_VERSION"
  create_DB_schema "$UPGRADE_VERSION"
  install "$UPGRADE_VERSION"
  dump_DB "$UPGRADE_VERSION"
  create_DB_diff "$UPGRADE_VERSION"
  echo "--- Diff file create, see $DUMP_DIRECTORY/diff_${BASE_VERSION}_upgrated_${UPGRADE_VERSION}.txt ---"
fi

if dpkg --compare-versions "$UPGRADE_VERSION" ge 9.0.0; then
  export PRESTASHOP_RUN_VERSION=8.1-apache
  docker compose build prestashop-run
else
  docker compose build prestashop-run
fi

docker compose up -d prestashop-run
echo "--- Docker container created for upgrade, see result at http://localhost:8002/admin ---"

FRONT_CONTAINER_NAME="visualize-diff-front"
BACK_CONTAINER_NAME="visualize-diff-back"

if ! docker ps -f name=${BACK_CONTAINER_NAME} | grep -q ${BACK_CONTAINER_NAME}; then
    echo "Launching ${BACK_CONTAINER_NAME}"
    docker compose up -d ${BACK_CONTAINER_NAME}
fi

if ! docker ps -f name=${FRONT_CONTAINER_NAME} | grep -q ${FRONT_CONTAINER_NAME}; then
    echo "Launching ${FRONT_CONTAINER_NAME}"
    docker compose up -d ${FRONT_CONTAINER_NAME}
fi

echo "--- If you want to check diff, see diff tool at http://localhost:8080/ ---"
