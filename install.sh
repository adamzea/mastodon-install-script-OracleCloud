#!/bin/bash

# Ingress rules warning
echo "Before continuing make sure you have an A record in your DNS for your domain that points to the public IP address of your server. Also be sure to set up ingress rules in your instance's security list for port 80 and 443. See: https://blogs.oracle.com/cloud-infrastructure/post/a-simple-guide-to-adding-rules-to-security-lists-using-oci-cli"
# Input server domain
read -p "Input your server domain without \"http\" (e.g. mastodon.example.com) > " SERVER_FQDN
read -p "Obtain SSL Cert ? [y/N] > " SSL_CERT

if [ "$SSL_CERT" == "y" -o "$SSL_CERT" == "Y" ]
then
  read -p "Input your mail adress > " ADMIN_MAIL_ADDRESS
else
  echo ""
fi

DEBIAN_FRONTEND=noninteractive
# Pre-requisite
# Uninstall iptables
sudo apt remove iptables -y
# Open ports
#sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT && sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
#sudo netfilter-persistent save
## system repository
echo "installing pre-requisite"
sudo apt install -y curl wget git gnupg apt-transport-https lsb-release ca-certificates
## Node.js v16
curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
## PostgreSQL
sudo wget -O /usr/share/keyrings/postgresql.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/keyrings/postgresql.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/postgresql.list

# Correct permission ~/.config
sudo mkdir -p ~/.config
sudo chown mastodon:mastodon ~/.config

# Clone Mastodon
sudo apt update
sudo apt upgrade -y
sudo apt install -y git curl ufw
echo "cloning mastodon repository"
git clone https://github.com/mastodon/mastodon.git ~/live
git checkout $(git tag -l | grep -v 'rc[0-9]*$' | sort -V | tail -n 1)
cd ~/live

# Install packages
echo "installing packages"
sudo apt install -y \
  imagemagick ffmpeg libpq-dev libxml2-dev libxslt1-dev file git-core \
  g++ libprotobuf-dev protobuf-compiler pkg-config nodejs gcc autoconf \
  bison build-essential libssl-dev libyaml-dev libreadline6-dev \
  zlib1g-dev libncurses5-dev libffi-dev libgdbm-dev \
  nginx redis-server redis-tools postgresql postgresql-contrib \
  certbot python3-certbot-nginx libidn11-dev libicu-dev libjemalloc-dev
## (c.f. https://qiita.com/yakumo/items/10edeca3742689bf073e about not needing to install "libgdbm5")

# Install Ruby and gem(s)
if [ -d ~/.rbenv ]
then
  echo "" > /dev/null
else
  echo "installing rbenv"
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
  cd ~/.rbenv && src/configure && make -C src
  echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
  echo 'eval "$(rbenv init -)"' >> ~/.bashrc
  export  PATH=$HOME/.rbenv/bin:$PATH
  eval "$(rbenv init -)"
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
  cd -
fi
echo "installing ruby"
source ~/.bashrc
echo N | RUBY_CONFIGURE_OPTS="--with-jemalloc" rbenv install $(cat ~/live/.ruby-version)
rbenv global $(cat ~/live/.ruby-version)

# Setup ufw
echo y | sudo ufw enable
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 22 #sshシャットアウト対策

# Install yarn
echo "installing yarn"
sudo npm install -g yarn
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list

# Obtain SSL Cert
if [ "$SSL_CERT" == "y" -o "$SSL_CERT" == "Y" ]
then
  echo "obtaining SSL Cert"
  sudo certbot certonly -d $SERVER_FQDN -m $ADMIN_MAIL_ADDRESS -n --nginx --agree-tos
  echo "@daily certbot renew --renew-hook \"service nginx restart\"" | sudo tee -a /etc/cron.d/certbot-renew
else
  echo ""
fi
# Setup PostgreSQL
echo "setting up PostgreSQL"
echo "CREATE USER mastodon CREATEDB" | sudo -u postgres psql -f -

# Setup Mastodon
rbenv global $(cat ~/live/.ruby-version)
cd ~/live
echo "setting up Gem"
gem install bundler --no-document
bundle config deployment true
bundle config without 'development test'
bundle install -j$(getconf _NPROCESSORS_ONLN)
yarn install --pure-lockfile --network-timeout 100000
echo "setting up Mastodon"
RAILS_ENV=production bundle exec rake mastodon:setup


# Set up nginx
cp ~/live/dist/nginx.conf ~/live/dist/$SERVER_FQDN.conf
sed -i ~/live/dist/$SERVER_FQDN.conf -e "s/example.com/$SERVER_FQDN/g"
if [ "$SSL_CERT" == "y" -o "$SSL_CERT" == "Y" ]
then
  sed -i ~/live/dist/$SERVER_FQDN.conf -e 's/# ssl_certificate/ssl_certificate/g'
else
  echo "" > /dev/null
fi
sudo cp /home/mastodon/live/dist/$SERVER_FQDN.conf /etc/nginx/conf.d/$SERVER_FQDN.conf

# Fix permissions
sudo usermod --append --groups mastodon www-data

# Set up systemd services
echo "setting up systemd services"
sudo cp /home/mastodon/live/dist/mastodon-*.service /etc/systemd/system/
sudo systemctl enable --now mastodon-web.service mastodon-streaming.service mastodon-sidekiq.service
sudo systemctl restart nginx.service

# Set up disk cleanup script
sudo tee purge-media.sh <<EOF
#!/bin/bash
# Source: https://ricard.dev/improving-mastodons-disk-usage/
# Prune remote accounts that never interacted with a local user
RAILS_ENV=production /home/mastodon/live/bin/tootctl accounts prune;

# Remove remote statuses that local users never interacted with older than 4 days
RAILS_ENV=production /home/mastodon/live/bin/tootctl statuses remove --days 4;

# Remove media attachments older than 4 days
RAILS_ENV=production /home/mastodon/live/bin/tootctl media remove --days 4;

# Remove all headers (including people I follow)
RAILS_ENV=production /home/mastodon/live/bin/tootctl media remove --remove-headers --include-follows --days 0;

# Remove link previews older than 4 days
RAILS_ENV=production /home/mastodon/live/bin/tootctl preview_cards remove --days 4;

# Remove files not linked to any post
RAILS_ENV=production /home/mastodon/live/bin/tootctl media remove-orphans; 
EOF
sudo apt install cron
(crontab -l ; echo "0 5 * * 1 purge-media.sh") | sort - | uniq - | crontab - 

echo "done :tada:"
