#!/bin/bash
# Create Key/CSR/CRT signed by FreeIPA
# greg.procunier@gmail.com [08-03-2019]
#
# hero mode for those times you can't go all-in with freeipa+novajoin 
# but still want public SSL endpoints

declare -A config
config["overcloudHost"]="overcloud.idm.example.com"
config["ipaRealm"]="IDM.EXAMPLE.COM"
config["keyLocation"]="/home/stack/ssl-build/overcloud.idm.example.com.key.pem"
config["csrLocation"]="/home/stack/ssl-build/overcloud.idm.example.com.csr.pem"
config["crtLocation"]="/home/stack/ssl-build/overcloud.idm.example.com.crt.pem"
config["chownTarget"]="stack:stack"
config["keyBits"]="2048"
config["openssl_cnf"]="/etc/pki/tls/openssl.cnf"
config["ipaAdmin"]="admin"

declare -a sanHosts
sanHosts[0]='DNS:overcloud.idm.example.com'
sanHosts[1]='DNS:overcloud.ctlplane.idm.example.com'
sanHosts[2]='DNS:overcloud.internalapi.idm.example.com'
sanHosts[3]='DNS:overcloud.storage.idm.example.com'
sanHosts[4]='DNS:overcloud.storagemgmt.idm.example.com'
sanHosts[5]='DNS:overcloud.storagenfs.idm.example.com'


### Main

trap "exit 1" TERM
export MAIN=$$

for bin in /usr/bin/ipa /usr/bin/kdestroy /usr/bin/kinit /usr/bin/sudo /bin/ipa-getcert /usr/bin/cat /usr/bin/openssl /usr/bin/mkdir
do
  command -v $bin >/dev/null || ( echo "$bin is required to operate" && kill -s TERM $MAIN )
done

[[ ! -d "${config['keyLocation']%/*}" ]] && /usr/bin/mkdir "${config['keyLocation']%/*}"


[[ ! -f "${config['keyLocation']}" ]] && \
  /usr/bin/openssl genrsa -out "${config['keyLocation']}" "${config['keyBits']}"

read -r -d '' SAN <<-__EOF__
[SAN]
subjectAltName=$(printf "%s," ${sanHosts[@]})
__EOF__

[[ ! -f "$config['keyLocation']}" ]] && \
  /usr/bin/openssl req \
                   -new \
                   -sha256 \
                   -key "${config['keyLocation']}" \
                   -subj "/CN=${config['overcloudHost']}/O=${config['ipaRealm']}" \
                   -reqexts SAN \
                   -config <(/usr/bin/cat "${config['openssl_cnf']}"  <(echo "${SAN%,}")) \
                   -out "${config['csrLocation']}"


/usr/bin/kdestroy >/dev/null 2>&1
/usr/bin/kinit "${config['ipaAdmin']}"

for host in $(printf "%s " "${sanHosts[@]//DNS:}")
do
  if /usr/bin/ipa host-show $host >/dev/null 2>&1
  then
    echo "$host exists - skipping"
  else
    echo "Adding $host to IPA"
    /usr/bin/ipa host-add $host >/dev/null 2>&1
  fi
  if /usr/bin/ipa service-show "osp/$host@${config['ipaRealm']}" >/dev/null 2>&1
  then
    echo "osp/$host@${config['ipaRealm']} exists - skipping"
  else
    echo "Adding service osp/$host@${config['ipaRealm']} to be managed by $(hostname --fqdn)"
    /usr/bin/ipa service-add "osp/$host@${config['ipaRealm']}" >/dev/null 2>&1
    /usr/bin/ipa service-add-host --hosts=$(hostname --fqdn) "osp/$host@${config['ipaRealm']}" >/dev/null 2>&1
  fi
  DNS="$DNS -D $host"
done

/usr/bin/sudo ipa-getcert request -r \
  -f "${config['crtLocation']}" \
  -k "${config['keyLocation']}" \
  -N CN="${config['overcloudHost']}" \
  -C "/usr/bin/chown ${config['chownTarget']} ${config['crtLocation']}" \
  -K "osp/${config['overcloudHost']}" \
  $DNS
