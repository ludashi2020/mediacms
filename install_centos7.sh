#!/bin/bash
# should be run as root on a centos7 system

# Disable SELinux
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

function update_permissions
{
	# fix permissions of /srv/mediacms directory
	chown -R nginx:root $1
}

echo "Welcome to the MediacMS installation!";

if [ `id -u` -ne 0 ]; then
	echo "Please run as root user"
	exit
fi

while true; do
    read -p "
This script will attempt to perform a system update, install required dependencies, and configure PostgreSQL, NGINX, Redis and a few other utilities.
It is expected to run on a new system **with no running instances of any these services**. Make sure you check the script before you continue. Then enter y or n
" yn
    case $yn in
        [Yy]* ) echo "OK!"; break;;
        [Nn]* ) echo "Have a great day"; exit;;
        * ) echo "Please answer y or n.";;
    esac
done

# update configuration files

sed -i 's/\/home\/mediacms\.io\/mediacms\/Bento4-SDK-1-6-0-637\.x86_64-unknown-linux\/bin\/mp4hls/\/srv\/mediacms\/bento4\/bin\/mp4hls/g' cms/settings.py
sed -i 's/www-data/nginx/g;s/\/home\/mediacms\.io\/mediacms\/logs/\/var\/log\/mediacms/g;s/\/home\/mediacms\.io\/mediacms/\/srv\/mediacms/g;s/\/home\/mediacms\.io\/bin/\/srv\/mediacms\/virtualenv\/bin/g' deploy/local_install/celery_*.service
sed -i 's/\/home\/mediacms\.io\/mediacms/\/srv\/mediacms/g' deploy/local_install/mediacms.io
sed -i 's/\/home\/mediacms\.io\/bin/\/srv\/mediacms\/virtualenv\/bin/g;s/\/home\/mediacms\.io\/mediacms/\/srv\/mediacms/g' deploy/local_install/mediacms.service
sed -i 's/\/home\/mediacms\.io\/mediacms/\/var\/log\/mediacms/g' deploy/local_install/mediacms_logrorate
sed -i 's/www-data/nginx/g' deploy/local_install/nginx.conf
sed -i 's/www-data/nginx/g;s/\/home\/mediacms\.io\/mediacms\/logs/\/var\/log\/mediacms/g;s/\/home\/mediacms\.io\/mediacms/\/srv\/mediacms/g;s/\/home\/mediacms\.io/\/srv\/mediacms\/virtualenv/g' deploy/local_install/uwsgi.ini

# CentOS 7 specific repositories and dependencies
yum install -y epel-release
yum install -y https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-7.noarch.rpm
yum install -y yum-utils

# Install required dependencies
yum install -y https://repo.ius.io/ius-release-el7.rpm  # for newer Python
yum install -y python3.6 python3.6-devel python3.6-pip python3.6-virtualenv
yum install -y redis postgresql-server postgresql-devel nginx git gcc vim unzip ImageMagick python-certbot-nginx certbot wget xz ffmpeg policycoreutils-devel cmake gcc-c++ bsdtar

# fix permissions of /srv/mediacms directory
update_permissions /srv/mediacms/

read -p "Enter portal URL, or press enter for localhost : " FRONTEND_HOST
read -p "Enter portal name, or press enter for 'MediaCMS : " PORTAL_NAME

[ -z "$PORTAL_NAME" ] && PORTAL_NAME='MediaCMS'
[ -z "$FRONTEND_HOST" ] && FRONTEND_HOST='localhost'

echo "Configuring postgres"
postgresql-setup initdb

# set authentication method for mediacms user to scram-sha-256
sed -i 's/.*password_encryption.*/password_encryption = scram-sha-256/' /var/lib/pgsql/data/postgresql.conf
sed -i '/# IPv4 local connections:/a host\tmediacms\tmediacms\t127.0.0.1/32\tscram-sha-256' /var/lib/pgsql/data/pg_hba.conf

systemctl enable postgresql
systemctl start postgresql

su -c "psql -c \"CREATE DATABASE mediacms\"" postgres
su -c "psql -c \"CREATE USER mediacms WITH ENCRYPTED PASSWORD 'mediacms'\"" postgres
su -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE mediacms TO mediacms\"" postgres

echo 'Creating python virtualenv on /srv/mediacms/virtualenv/'

mkdir -p /srv/mediacms/virtualenv/
cd /srv/mediacms/virtualenv/
virtualenv-3.6 . 
source /srv/mediacms/virtualenv/bin/activate
cd /srv/mediacms/
pip3.6 install -r requirements.txt

systemctl enable redis
systemctl start redis

SECRET_KEY=`python3.6 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'`

# remove http or https prefix
FRONTEND_HOST=`echo "$FRONTEND_HOST" | sed -r 's/http:\/\///g'`
FRONTEND_HOST=`echo "$FRONTEND_HOST" | sed -r 's/https:\/\///g'`

FRONTEND_HOST_HTTP_PREFIX='http://'$FRONTEND_HOST

echo 'FRONTEND_HOST='\'"$FRONTEND_HOST_HTTP_PREFIX"\' >> cms/local_settings.py
echo 'PORTAL_NAME='\'"$PORTAL_NAME"\' >> cms/local_settings.py
echo "SSL_FRONTEND_HOST = FRONTEND_HOST.replace('http', 'https')" >> cms/local_settings.py

echo 'SECRET_KEY='\'"$SECRET_KEY"\' >> cms/local_settings.py
echo "LOCAL_INSTALL = True" >> cms/local_settings.py

mkdir -p /var/log/mediacms/
mkdir -p pids

update_permissions /var/log/mediacms/

python3.6 manage.py migrate
python3.6 manage.py loaddata fixtures/encoding_profiles.json
python3.6 manage.py loaddata fixtures/categories.json
python3.6 manage.py collectstatic --noinput

ADMIN_PASS=`python3.6 -c "import secrets;chars = 'abcdefghijklmnopqrstuvwxyz0123456789';print(''.join(secrets.choice(chars) for i in range(10)))"`
echo "from users.models import User; User.objects.create_superuser('admin', 'admin@example.com', '$ADMIN_PASS')" | python3.6 manage.py shell

echo "from django.contrib.sites.models import Site; Site.objects.update(name='$FRONTEND_HOST', domain='$FRONTEND_HOST')" | python3.6 manage.py shell

update_permissions /srv/mediacms/

cp deploy/local_install/celery_long.service /etc/systemd/system/celery_long.service
cp deploy/local_install/celery_short.service /etc/systemd/system/celery_short.service
cp deploy/local_install/celery_beat.service /etc/systemd/system/celery_beat.service
cp deploy/local_install/mediacms.service /etc/systemd/system/mediacms.service

mkdir -p /etc/letsencrypt/live/$FRONTEND_HOST
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/dhparams/
rm -rf /etc/nginx/conf.d/default.conf
rm -rf /etc/nginx/sites-enabled/default
cp deploy/local_install/mediacms.io_fullchain.pem /etc/letsencrypt/live/$FRONTEND_HOST/fullchain.pem
cp deploy/local_install/mediacms.io_privkey.pem /etc/letsencrypt/live/$FRONTEND_HOST/privkey.pem
cp deploy/local_install/mediacms.io /etc/nginx/sites-available/mediacms.io
ln -s /etc/nginx/sites-available/mediacms.io /etc/nginx/sites-enabled/mediacms.io
cp deploy/local_install/uwsgi_params /etc/nginx/sites-enabled/uwsgi_params
cp deploy/local_install/nginx.conf /etc/nginx/

# attempt to get a valid certificate for specified domain
while true ; do
        echo "Would you like to run [c]ertbot, or [s]kip?"
        read -p " : " certbotConfig

        case $certbotConfig in
        [cC*] )
		if [ "$FRONTEND_HOST" != "localhost" ]; then
			systemctl start nginx
			echo "Attempting to get a valid certificate for specified url $FRONTEND_HOST"
			certbot --nginx -n --agree-tos --register-unsafely-without-email -d $FRONTEND_HOST
			certbot --nginx -n --agree-tos --register-unsafely-without-email -d $FRONTEND_HOST
			systemctl stop nginx

			# Generate individual DH params
			openssl dhparam -out /etc/nginx/dhparams/dhparams.pem 4096
		fi

                break
                ;;
        [sS*] )
		echo "Will not call certbot utility to update ssl certificate for url 'localhost', using default ssl certificate"
		cp deploy/local_install/dhparams.pem /etc/nginx/dhparams/dhparams.pem

                break
                ;;
        * )
                echo "Unknown option: $certbotConfig"
                ;;
        esac
done

# configure bento4 utility installation, for HLS
while true ; do
	echo "Configuring Bento4"
	echo "Would you like to [d]ownload a pre-compiled bento4 binary, or [b]uild it now?"
	read -p "b/d : " bentoConfig

	case $bentoConfig in
	[bB*] )
		echo "Building bento4 from source"
		git clone -b v1.6.0-640 https://hub.dd.ci/axiomatic-systems/Bento4 /srv/mediacms/bento4
		cd /srv/mediacms/bento4/
		mkdir bin
		cd /srv/mediacms/bento4/bin/
		cmake -DCMAKE_BUILD_TYPE=Release ..
		make -j$(nproc)

		chmod +x ../Source/Python/utils/mp4-hls.py

		echo -e '#!/bin/bash' >> mp4hls
		echo -e 'BASEDIR=$(pwd)' >> mp4hls
		echo -e 'exec python3 "$BASEDIR/../Source/Python/utils/mp4-hls.py"' >> mp4hls

		chmod +x mp4hls

		break
		;;
	[dD*] )
		cd /srv/mediacms/
		wget http://zebulon.bok.net/Bento4/binaries/Bento4-SDK-1-6-0-637.x86_64-unknown-linux.zip
		tar -xf Bento4-SDK-1-6-0-637.x86_64-unknown-linux.zip -s '/Bento4-SDK-1-6-0-637.x86_64-unknown-linux/bento4/'

		break
		;;
	* )
		echo "Unknown option: $bentoConfig"
		;;
	esac
done

mkdir -p /srv/mediacms/media_files/hls

# update permissions
update_permissions /srv/mediacms/

# 完全移除原有的 SELinux 配置部分，直接跳过

# configure firewall
if command -v firewall-cmd > /dev/null 2>&1 ; then
	while true ; do
	        echo "Configuring firewall"
	        echo "Would you like to configure http, https, or skip and not do any firewall configuration?"
	        read -p "http/https/skip : " fwConfig

		case $fwConfig in
	        http )
	                echo "Opening port 80 until next reboot"
			firewall-cmd --add-port=80/tcp
	                break
	                ;;
	        https )
			echo "Opening port 443 permanently"
			firewall-cmd --add-port=443/tcp --permanent
			firewall-cmd --reload
	                break
	                ;;
	        skip )
	                echo "Skipping firewall configuration"
	                break
	                ;;
	        * )
	                echo "Unknown option: $fwConfig"
	                ;;
	        esac
	done
fi

systemctl daemon-reload
systemctl start celery_long
systemctl start celery_short
systemctl start celery_beat
systemctl start mediacms
systemctl start nginx

echo 'MediaCMS installation completed, open browser on http://'"$FRONTEND_HOST"' and login with user admin and password '"$ADMIN_PASS"''
