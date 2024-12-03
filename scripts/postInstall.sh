#set env vars
set -o allexport; source .env; set +o allexport;

#wait until the server is ready
echo "Waiting for software to be ready ..."
sleep 60s;

docker-compose down;

cat << EOT > ./uvdesk_app/vendor/doctrine/migrations/lib/Doctrine/Migrations/Configuration/Connection/Loader/ConnectionHelperLoader.php
<?php

declare(strict_types=1);

namespace Doctrine\Migrations\Configuration\Connection\Loader;

use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Tools\Console\Helper\ConnectionHelper;
use Doctrine\Migrations\Configuration\Connection\ConnectionLoaderInterface;
use Symfony\Component\Console\Helper\HelperSet;

/**
 * The ConnectionHelperLoader is responsible for loading a Doctrine\DBAL\Connection from a Symfony Console HelperSet.
 *
 * @internal
 */
class ConnectionHelperLoader implements ConnectionLoaderInterface
{
    /** @var string */
    private \$helperName;

    /** @var HelperSet */
    private \$helperSet;

    public function __construct(string \$helperName, ?HelperSet \$helperSet = null)
    {
        \$this->helperName = \$helperName;

        if (\$helperSet === null) {
            \$helperSet = new HelperSet();
        }

        \$this->helperSet = \$helperSet;
    }

    /**
     * Read the input and return a Configuration, returns null if the config
     * is not supported.
     */
    public function chosen(): ?Connection
    {
        if (\$this->helperSet->has(\$this->helperName)) {
            \$connectionHelper = \$this->helperSet->get(\$this->helperName);

            if (\$connectionHelper instanceof ConnectionHelper) {
                return \$connectionHelper->getConnection();
            }
        }

        return null;
    }
}
EOT

cat << EOT > ./uvdesk_app/vendor/doctrine/migrations/lib/Doctrine/Migrations/Tools/Console/ConnectionLoader.php
<?php

declare(strict_types=1);

namespace Doctrine\Migrations\Tools\Console;

use Doctrine\DBAL\Connection;
use Doctrine\Migrations\Configuration\Configuration;
use Doctrine\Migrations\Configuration\Connection\ConnectionLoaderInterface;
use Doctrine\Migrations\Configuration\Connection\Loader\ArrayConnectionConfigurationLoader;
use Doctrine\Migrations\Configuration\Connection\Loader\ConnectionConfigurationChainLoader;
use Doctrine\Migrations\Configuration\Connection\Loader\ConnectionConfigurationLoader;
use Doctrine\Migrations\Configuration\Connection\Loader\ConnectionHelperLoader;
use Doctrine\Migrations\Tools\Console\Exception\ConnectionNotSpecified;
use Symfony\Component\Console\Helper\HelperSet;
use Symfony\Component\Console\Input\InputInterface;

use function assert;
use function is_string;

/**
 * The ConnectionLoader class is responsible for loading the Doctrine\DBAL\Connection instance to use for migrations.
 *
 * @internal
 */
class ConnectionLoader
{
    /** @var Configuration|null */
    private \$configuration;

    public function __construct(?Configuration \$configuration)
    {
        \$this->configuration = \$configuration;
    }

    public function getConnection(InputInterface \$input, HelperSet \$helperSet): Connection
    {
        \$connection = \$this->createConnectionConfigurationChainLoader(\$input, \$helperSet)
            ->chosen();

        if (\$connection !== null) {
            return \$connection;
        }

        throw ConnectionNotSpecified::new();
    }

    protected function createConnectionConfigurationChainLoader(
        InputInterface \$input,
        HelperSet \$helperSet
    ): ConnectionLoaderInterface {
        \$dbConfiguration = \$input->getOption('db-configuration');
        assert(is_string(\$dbConfiguration) || \$dbConfiguration === null);

        return new ConnectionConfigurationChainLoader([
            new ArrayConnectionConfigurationLoader(\$dbConfiguration),
            new ArrayConnectionConfigurationLoader('migrations-db.php'),
            new ConnectionHelperLoader('connection', \$helperSet),
            new ConnectionConfigurationLoader(\$this->configuration),
        ]);
    }
}
EOT

cat << EOT > ./uvdesk_app/config/packages/web_profiler.yaml
when@dev:
    web_profiler:
        toolbar: false
        intercept_redirects: false

    framework:
        profiler: { only_exceptions: false }

when@test:
    web_profiler:
        toolbar: false
        intercept_redirects: false

    framework:
        profiler: { collect: false }
EOT

cat << EOT > ./uvdesk_app/config/packages/framework.yaml
# see https://symfony.com/doc/current/reference/configuration/framework.html
framework:
    secret: '%env(APP_SECRET)%'
    #csrf_protection: true
    http_method_override: false

    # Enables session support. Note that the session will ONLY be started if you read or write from it.
    # Remove or comment this section to explicitly disable session support.
    session:
        handler_id: null
        cookie_secure: auto
        cookie_samesite: lax
        storage_factory_id: session.storage.factory.native

    #esi: true
    #fragments: true
    php_errors:
        log: true

    trusted_proxies: '*'
    trusted_headers: ['x-forwarded-for', 'x-forwarded-proto', 'x-forwarded-host', 'x-forwarded-port']
    assets:
        base_urls: ['https://${DOMAIN}']
    router:
        default_uri: 'https://${DOMAIN}'
        https_port: 443

when@test:
    framework:
        test: true
        session:
            storage_factory_id: session.storage.factory.mock_file

EOT

cat << EOT > ./uvdesk_app/config/packages/routing.yaml
framework:
    router:
        utf8: true

        # Configure how to generate URLs in non-HTTP contexts, such as CLI commands.
        # See https://symfony.com/doc/current/routing.html#generating-urls-in-commands
        #default_uri: http://localhost
        default_uri: 'https://${DOMAIN}'

when@prod:
    framework:
        router:
            strict_requirements: null

EOT

cat /opt/elestio/startPostfix.sh > post.txt
filename="./post.txt"

SMTP_LOGIN=""
SMTP_PASSWORD=""


# Read the file line by line
while IFS= read -r line; do
  # Extract the values after the flags (-e)
  values=$(echo "$line" | grep -o '\-e [^ ]*' | sed 's/-e //')

  # Loop through each value and store in respective variables
  while IFS= read -r value; do
    if [[ $value == RELAYHOST_USERNAME=* ]]; then
      SMTP_LOGIN=${value#*=}
    elif [[ $value == RELAYHOST_PASSWORD=* ]]; then
      SMTP_PASSWORD=${value#*=}
    fi
  done <<< "$values"

done < "$filename"

rm post.txt

ENCODED_PASSWORD=$(echo -n "$SMTP_PASSWORD" | base64)

cat << EOT > ./uvdesk_app/config/packages/swiftmailer.yaml
swiftmailer:
    default_mailer: mailer_0286
    mailers:
        mailer_0286:
            transport: smtp
            username: ${SMTP_LOGIN}
            password: ${ENCODED_PASSWORD}
            host: tuesday.mxrouting.net
            port: 465
            encryption: ssl
            auth_mode: login
            sender_address: ${SMTP_LOGIN}
            delivery_addresses: ['']
            disable_delivery: false


EOT

cat << EOT > ./uvdesk_app/config/packages/doctrine.yaml
parameters:
    # Adds a fallback DATABASE_URL if the env var is not set.
    # This allows you to run cache:warmup even if your
    # environment variables are not available yet.
    # You should not need to change this value.
    env(DATABASE_URL): ''

doctrine:
    dbal:
        # configure these for your database server
        driver: 'pdo_mysql'
        server_version: '5.7'
        charset: utf8mb4
        default_table_options:
            charset: utf8mb4
            collate: utf8mb4_unicode_ci

        url: '${DATABASE_URL}'
        options:
            1002: 'SET sql_mode=(SELECT REPLACE(@@sql_mode, "ONLY_FULL_GROUP_BY", ""))'
    orm:
        auto_generate_proxy_classes: true
        naming_strategy: doctrine.orm.naming_strategy.underscore
        auto_mapping: true
        mappings:
            App:
                is_bundle: false
                type: annotation
                dir: '%kernel.project_dir%/src/Entity'
                prefix: 'App\Entity'
                alias: App

EOT

sed -i "s|support_email: ~|support_email:\n        id: ${ADMIN_EMAIL}\n        name: UVDesk Community\n        mailer_id: mailer_0286|g" ./uvdesk_app/config/packages/uvdesk.yaml

sed -i "s|site_url: 'localhost:8000'|site_url: '${DOMAIN}'|g" ./uvdesk_app/config/packages/uvdesk.yaml

sed -i "s|        // Create a message|        // Create a message\n\n        \$content = str_replace('http://', 'https://', \$content);\n|g" ./uvdesk_app/vendor/uvdesk/core-framework/Services/EmailService.php

sed -i "s|\$_SESSION\['DB_CONFIG'\]\['host'\]|'172.17.0.1'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['DB_CONFIG'\]\['port'\]|'24831'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['DB_CONFIG'\]\['version'\]|''|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['DB_CONFIG'\]\['username'\]|'root'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['DB_CONFIG'\]\['password'\]|'${DATABASE_PASSWORD}'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['DB_CONFIG'\]\['database'\]|'uvdesk'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['DB_CONFIG'\]\['createDatabase'\]|1|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php

sed -i "s|\$request->request->get('name')|'admin'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$request->request->get('email')|'${ADMIN_EMAIL}'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$request->request->get('password')|'${ADMIN_PASSWORD}'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|array_values(\$_SESSION\['USER_DETAILS'\])|\['admin','${ADMIN_EMAIL}','${ADMIN_PASSWORD}'\]|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['USER_DETAILS'\]\['name'\]|'admin'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php
sed -i "s|\$_SESSION\['USER_DETAILS'\]\['email'\]|'${ADMIN_EMAIL}'|g" ./uvdesk_app/src/Controller/ConfigureHelpdesk.php

sed -i "s|\[0 => 'https://${DOMAIN}']|'//'|g" ./uvdesk_app/var/cache/prod/ContainerNlMEQbo/getUvdeskExtension_AssetsManagerService.php



docker-compose up -d;
sleep 15s;

target=$(docker-compose port uvdesk 80)

curl http://${target}/wizard/xhr/check-requirements \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'specification=php-version'

  curl http://${target}/wizard/xhr/check-requirements \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'specification=php-extensions'

  curl http://${target}/wizard/xhr/check-requirements \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'specification=php-maximum-execution'

  curl http://${target}/wizard/xhr/check-requirements \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'specification=php-envfile-permission'

  curl http://${target}/wizard/xhr/check-requirements \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'specification=php-configfiles-permission'

curl http://${target}/wizard/xhr/verify-database-credentials \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'serverName=172.17.0.1&serverVersion=&serverPort=24831&username=root&password='${ADMIN_PASSWORD}'&database=uvdesk&createDatabase=1'

  curl http://${target}/wizard/xhr/intermediary/super-user \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'name=admin&email='${ADMIN_EMAIL}'&password='${ADMIN_PASSWORD}''

  curl http://${target}/wizard/xhr/website-configure \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest'

  curl http://${target}/wizard/xhr/website-configure \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest' \
  --data-raw 'member-prefix=member&customer-prefix=customer'

  curl http://${target}/wizard/xhr/load/configurations \
  -X 'POST' \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-length: 0' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest'

  curl http://${target}/wizard/xhr/load/migrations \
  -X 'POST' \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-length: 0' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest'

  curl http://${target}/wizard/xhr/load/entities \
  -X 'POST' \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-length: 0' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest'

  curl http://${target}/wizard/xhr/load/super-user \
  -X 'POST' \
  -H 'accept: */*' \
  -H 'accept-language: fr,fr-FR;q=0.9,en-US;q=0.8,en;q=0.7,he;q=0.6,zh-CN;q=0.5,zh;q=0.4,ja;q=0.3' \
  -H 'cache-control: no-cache' \
  -H 'content-length: 0' \
  -H 'pragma: no-cache' \
  -H 'priority: u=1, i' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'x-requested-with: XMLHttpRequest'

docker-compose down;

sed -i "s~APP_ENV=dev~APP_ENV=prod~g" ./docker-compose.yml

docker-compose up -d;

sleep 20s;