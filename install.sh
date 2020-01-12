#!/bin/bash

########### 判断os ##############
OS=""
if [ "$(uname)" == "Darwin" ];then
  OS=darwin
elif [ "$(expr substr "$(uname -s)" 1 5)" == "Linux" ];then
  OS=linux
elif [ "$(expr substr "$(uname -s)" 1 10)" == "MINGW32_NT" ];then
  echo "暂不支持windows系统"
  exit 1
fi
#################################

############ 全局变量 #############
# k8s版本
K8S_VERSION="1.17.0"
K8S_DIR="kubernetes"
# k8s集群证书目录
K8S_SSL_DIR="/etc/kubernetes/ssl" && sudo mkdir -p $K8S_SSL_DIR

#############flanneld############
# flanneld版本号
FLANNELD_VERSION=0.11.0
# 下载目录
FLANNELD_DIR="flanneld" && mkdir -p $FLANNELD_DIR
# flanneld ssl证书目录
FLANNELD_SSL_DIR="/etc/flanneld/ssl" && sudo mkdir -p $FLANNELD_SSL_DIR

# 工作目录
WORK_DIR="/usr/k8s/bin" && sudo mkdir -p $WORK_DIR
# ENV脚本路径
ENV_FILE="env.sh"

# 集群所有机器ip
IPS="10.211.55.8 10.211.55.9 10.211.55.10 10.211.55.11"
# 集群master节点
MASTER_URL="10.211.55.8"

# 设置CFSSL版本
CFSSL_VERSION=1.4.1
# CFSSL安装目录
SSL_DIR=ssl && mkdir -p $SSL_DIR

##############etcd###############
# etcd版本号
ETCD_VERSION=3.3.18
# etcd下载目录
ETCD_DIR=etcd && mkdir -p $ETCD_DIR
# etcd集群ip列表
NODE_IPS="10.211.55.8 10.211.55.9"
# etcd数据目录
ETCD_DATA_DIR="/var/lib/etcd"
# etcd证书目录
ETCD_SSL_DIR="/etc/etcd/ssl"
# etcd 集群间通信的IP和端口
ETCD_NODES=etcd1=https://10.211.55.8:2380,etcd2=https://10.211.55.9:2380
# etcd endpoinds
ETCD_ENDPOINTS="https://10.211.55.8:2379,https://10.211.55.9:2379"
#################################

# 环境变量
export PATH=$WORK_DIR:$SSL_DIR:$PATH

# CFSSL安装和配置
if [[ ! -f "$SSL_DIR/cfssl" ]] || [[ ! -f "$SSL_DIR/cfssljson" ]] || [[ ! -f "$SSL_DIR/cfssl-certinfo" ]]; then
  wget https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_${OS}_amd64 -O $SSL_DIR/cfssl && chmod +x $SSL_DIR/cfssl
  wget https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_${OS}_amd64 -O $SSL_DIR/cfssljson && chmod +x $SSL_DIR/cfssljson
  wget https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl-certinfo_${CFSSL_VERSION}_${OS}_amd64 -O $SSL_DIR/cfssl-certinfo && chmod +x $SSL_DIR/cfssl-certinfo
  # CFSSL配置
  cat > $SSL_DIR/ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
       "kubernetes": {
          "expiry": "87600h",
           "usages": [
              "signing",
              "key encipherment",
              "server auth",
              "client auth"
           ]
       }
    }
  }
}
EOF

  cat > $SSL_DIR/ca-csr.json << EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
       "C": "CN",
       "L": "ShangHai",
       "ST": "ShangHai",
       "O": "k8s",
       "OU": "System"
    }
  ]
}
EOF
  # 生成CA证书
  cfssl gencert -initca $SSL_DIR/ca-csr.json | cfssljson -bare $SSL_DIR/ca
fi

# 下载etcd
if [[ ! -f "$ETCD_DIR/etcd-v$ETCD_VERSION-linux-amd64.tar.gz" ]];then
  wget https://github.com/coreos/etcd/releases/download/v$ETCD_VERSION/etcd-v$ETCD_VERSION-linux-amd64.tar.gz -O $ETCD_DIR/etcd-v$ETCD_VERSION-linux-amd64.tar.gz
  tar -xf $ETCD_DIR/etcd-v$ETCD_VERSION-linux-amd64.tar.gz -C $ETCD_DIR/
fi
if [[ "$OS" == "darwin" ]] && [[ ! -f "$ETCD_DIR/etcd-v$ETCD_VERSION-darwin-amd64.zip" ]];then
  wget https://github.com/coreos/etcd/releases/download/v$ETCD_VERSION/etcd-v$ETCD_VERSION-darwin-amd64.zip -O $ETCD_DIR/etcd-v$ETCD_VERSION-darwin-amd64.zip
  unzip -d $ETCD_DIR/ $ETCD_DIR/etcd-v$ETCD_VERSION-darwin-amd64.zip
fi

# 分别拷贝到集群每台机器
etcdIndex=0

# 遍历每台机器
for ip in $IPS;do
  # env脚本变量替换
  eval "cat <<EOF
$(< ${ENV_FILE})
EOF
" > $ENV_FILE
  # 拷env脚本
  ssh root@$ip "[ -d $WORK_DIR ] || mkdir -p $WORK_DIR"
  scp $ENV_FILE root@$ip:$WORK_DIR/
 
  # 创建k8s证书目录&拷贝证书
  ssh root@$ip "mkdir -p $K8S_SSL_DIR"
  scp -r $SSL_DIR/ca* root@$ip:$K8S_SSL_DIR/

  # 如果是etcd集群机器安装etcd
  for nodeIP in $NODE_IPS;do
      if [[ "$nodeIP" == "$ip" ]];then
        # index自增
        etcdIndex=$(($etcdIndex+1))
        {
        # etcd不存在则拷贝
        if ! ssh root@$ip test -e $WORK_DIR;then
            scp -r $ETCD_DIR/etcd-v$ETCD_VERSION-linux-amd64/etcd* root@$ip:$WORK_DIR/
        fi
        # 生成etcd证书配置文件
        mkdir -p $SSL_DIR/etcd$ip
        cat > $SSL_DIR/etcd$ip/etcd-$ip-csr.json << EOF
{
  "CN": "etcd",
  "hosts": [
    "127.0.0.1",
    "$ip"
  ],
  "key": {
   "algo": "rsa",
   "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "ShangHai",
      "L": "ShangHai",
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF
        # 生成etcd证书
        cfssl gencert -ca=$SSL_DIR/ca.pem \
  -ca-key=$SSL_DIR/ca-key.pem \
  -config=$SSL_DIR/ca-config.json \
  -profile=kubernetes $SSL_DIR/etcd$ip/etcd-$ip-csr.json | cfssljson -bare $SSL_DIR/etcd$ip/etcd

        # 拷贝etcd证书
        scp -r $SSL_DIR/etcd$ip/etcd*.pem root@$ip:$ETCD_SSL_DIR/
        # 创建systemd unit文件
        ssh root@$ip "
# 存在服务就先关闭服务
if [ -f /etc/systemd/system/etcd.service ];then
  systemctl stop etcd
fi
# 创建etcd相关目录
rm -rf $ETCD_DATA_DIR && mkdir -p $ETCD_DATA_DIR

cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=simple
WorkingDirectory=${ETCD_DATA_DIR}
ExecStart=${WORK_DIR}/etcd \\
  --name=etcd${etcdIndex} \\
  --cert-file=${ETCD_SSL_DIR}/etcd.pem \\
  --key-file=${ETCD_SSL_DIR}/etcd-key.pem \\
  --peer-cert-file=${ETCD_SSL_DIR}/etcd.pem \\
  --peer-key-file=${ETCD_SSL_DIR}/etcd-key.pem \\
  --trusted-ca-file=${K8S_SSL_DIR}/ca.pem \\
  --peer-trusted-ca-file=${K8S_SSL_DIR}/ca.pem \\
  --initial-advertise-peer-urls=https://${nodeIP}:2380 \\
  --listen-peer-urls=https://${nodeIP}:2380 \\
  --listen-client-urls=https://${nodeIP}:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls=https://${nodeIP}:2379 \\
  --initial-cluster-token=etcd-cluster-0 \\
  --initial-cluster=${ETCD_NODES} \\
  --initial-cluster-state=new \\
  --data-dir=${ETCD_DATA_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
systemctl status etcd
"
      }&
      sleep 5
      else
        if ssh root@$ip test -e $WORK_DIR/etcdctl;then
          echo "文件:etcdctl 已存在，跳过"
          else
          scp -r $ETCD_DIR/etcd-v$ETCD_VERSION-linux-amd64/etcdctl root@$ip:$WORK_DIR/
        fi
      fi
  done
done

# 检查etcd集群状态是否正常
sleep 5
ssh root@$(echo "$NODE_IPS" | awk '{print $1}') "
${WORK_DIR}/etcdctl  \\
--ca-file=${K8S_SSL_DIR}/ca.pem \\
--cert-file=${ETCD_SSL_DIR}/etcd.pem \\
--key-file=${ETCD_SSL_DIR}/etcd-key.pem \\
cluster-health
"

# 安装kubectl命令行工具
source $ENV_FILE
# 因为我们还没有安装haproxy，所以暂时需要手动指定使用apiserver的6443端口，等haproxy安装完成后就可以用使用443端口转发到6443端口
KUBE_APISERVER="https://${MASTER_URL}:6443"

# 下载kubernetes-client
mkdir -p $K8S_DIR
if [[ ! -f "$K8S_DIR/kubernetes-client-$OS-amd64.tar.gz" ]];then
wget https://storage.googleapis.com/kubernetes-release/release/v$K8S_VERSION/kubernetes-client-$OS-amd64.tar.gz -O $K8S_DIR/kubernetes-client-$OS-amd64.tar.gz
tar -xf $K8S_DIR/kubernetes-client-$OS-amd64.tar.gz -C $K8S_DIR/
cp -r $K8S_DIR/kubernetes/client/bin/kube* $WORK_DIR/
chmod +x $WORK_DIR/kube*
fi

# 创建admin证书
cat > $SSL_DIR/admin-csr.json <<EOF
{
  "CN": "admin",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "ShangHai",
      "L": "ShangHai",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF
# 生成admin证书和私钥
mkdir -p $SSL_DIR/admin
cfssl gencert -ca=$SSL_DIR/ca.pem \
  -ca-key=$SSL_DIR/ca-key.pem \
  -config=$SSL_DIR/ca-config.json \
  -profile=kubernetes $SSL_DIR/admin-csr.json | cfssljson -bare $SSL_DIR/admin/admin
cp -rf $SSL_DIR/admin/admin*.pem $K8S_SSL_DIR/
cp -rf $SSL_DIR/ca.pem $K8S_SSL_DIR/

# 创建kubectl kubeconfig 文件
# 设置集群参数
${WORK_DIR}/kubectl config set-cluster kubernetes \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --certificate-authority=${K8S_SSL_DIR}/ca.pem
# 设置客户端认证参数
${WORK_DIR}/kubectl config set-credentials admin \
  --client-certificate=${K8S_SSL_DIR}/admin.pem \
  --embed-certs=true \
  --client-key=${K8S_SSL_DIR}/admin-key.pem \
  --token=${BOOTSTRAP_TOKEN}
# 设置上下文参数
${WORK_DIR}/kubectl config set-context kubernetes \
  --cluster=kubernetes \
  --user=admin
# 使用默认上下文
${WORK_DIR}/kubectl config use-context kubernetes

################ 部署Flannel 网络 #################
cat > $SSL_DIR/flanneld-csr.json <<EOF
{
  "CN": "flanneld",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "ShangHai",
      "L": "ShangHai",
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF
mkdir -p $SSL_DIR/flanneld
cfssl gencert -ca=$SSL_DIR/ca.pem \
  -ca-key=$SSL_DIR/ca-key.pem \
  -config=$SSL_DIR/ca-config.json \
  -profile=kubernetes $SSL_DIR/flanneld-csr.json | cfssljson -bare $SSL_DIR/flanneld/flanneld

# 下载flanneld
if [[ ! -f "$FLANNELD_DIR/flannel-v$FLANNELD_VERSION-linux-amd64.tar.gz" ]];then
  wget https://github.com/coreos/flannel/releases/download/v$FLANNELD_VERSION/flannel-v$FLANNELD_VERSION-linux-amd64.tar.gz -O $FLANNELD_DIR/flannel-v$FLANNELD_VERSION-linux-amd64.tar.gz
  tar -xf $FLANNELD_DIR/flannel-v$FLANNELD_VERSION-linux-amd64.tar.gz -C $FLANNELD_DIR/
fi

# 给集群各个节点安装flanneld
for ip in ${IPS};do
  ssh root@$ip "mkdir -p $FLANNELD_SSL_DIR"
  # flanneld证书拷贝
  scp -r $SSL_DIR/flanneld/flanneld*.pem root@$ip:$FLANNELD_SSL_DIR/
  # 关闭flanneld服务
  ssh root@$ip "
    if [[ -f /etc/systemd/system/flanneld.service ]];then
      systemctl stop flanneld
    fi
  "
  # 安装flanneld
  if ssh root@$ip test -e $WORK_DIR/flanneld;then
    echo "flanneld已存在，跳过"
    else
      scp -r $FLANNELD_DIR/{flanneld,mk-docker-opts.sh} root@$ip:$WORK_DIR/
  fi

  ssh root@$ip "
    export NODE_IP=$ip
    source $WORK_DIR/env.sh
    mkdir -p $FLANNELD_SSL_DIR

    if [[ -f "${WORK_DIR}/etcdctl" ]];then
      ${WORK_DIR}/etcdctl \\
      --endpoints=$ETCD_ENDPOINTS \\
      --ca-file=$K8S_SSL_DIR/ca.pem \\
      --cert-file=$FLANNELD_SSL_DIR/flanneld.pem \\
      --key-file=$FLANNELD_SSL_DIR/flanneld-key.pem \\
      set $FLANNEL_ETCD_PREFIX/config '{\"Network\":\"$CLUSTER_CIDR\", \"SubnetLen\": 24, \"Backend\": {\"Type\": \"vxlan\"}}'
    fi

    cat > /etc/systemd/system/flanneld.service <<EOF
[Unit]
Description=Flanneld overlay address etcd agent
After=network.target
After=network-online.target
Wants=network-online.target
After=etcd.service
Before=docker.service

[Service]
Type=notify
ExecStart=$WORK_DIR/flanneld \\
  -etcd-cafile=$K8S_SSL_DIR/ca.pem \\
  -etcd-certfile=$FLANNELD_SSL_DIR/flanneld.pem \\
  -etcd-keyfile=$FLANNELD_SSL_DIR/flanneld-key.pem \\
  -etcd-endpoints=$ETCD_ENDPOINTS \\
  -etcd-prefix=$FLANNEL_ETCD_PREFIX
ExecStartPost=$WORK_DIR/mk-docker-opts.sh -k DOCKER_NETWORK_OPTIONS -d /run/flannel/docker
Restart=on-failure

[Install]
WantedBy=multi-user.target
RequiredBy=docker.service
EOF
systemctl daemon-reload
systemctl enable flanneld
systemctl start flanneld
systemctl status flanneld
"
done

# 检查分配给各flanneld 的Pod 网段信息
echo "查看集群 Pod 网段(/16)"
${ETCD_DIR}/etcd-v$ETCD_VERSION-$OS-amd64/etcdctl \
  --endpoints=$ETCD_ENDPOINTS \
  --ca-file=$SSL_DIR/ca.pem \
  --cert-file=$SSL_DIR/flanneld/flanneld.pem \
  --key-file=$SSL_DIR/flanneld/flanneld-key.pem \
  get $FLANNEL_ETCD_PREFIX/config

echo "查看已分配的 Pod 子网段列表(/24)"
${ETCD_DIR}/etcd-v$ETCD_VERSION-$OS-amd64/etcdctl \
  --endpoints=$ETCD_ENDPOINTS \
  --ca-file=$SSL_DIR/ca.pem \
  --cert-file=$SSL_DIR/flanneld/flanneld.pem \
  --key-file=$SSL_DIR/flanneld/flanneld-key.pem \
  ls $FLANNEL_ETCD_PREFIX/subnets

echo "查看每个Pod网段对应的 flanneld 进程监听的 IP 和网络参数"
for ip in ${IPS};do
  ssh root@$ip "
    flannelIp=\`ip a|grep flannel.1|sed -n \"2, 1p\"| awk '{print \$2}'\`
    $WORK_DIR/etcdctl \\
    --endpoints=$ETCD_ENDPOINTS \\
    --ca-file=$K8S_SSL_DIR/ca.pem \\
    --cert-file=$FLANNELD_SSL_DIR/flanneld.pem \\
    --key-file=$FLANNELD_SSL_DIR/flanneld-key.pem \\
    get $FLANNEL_ETCD_PREFIX/subnets/\${flannelIp%/*}-24
  "
done


# 部署master节点
