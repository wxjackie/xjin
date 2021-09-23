---
title: "使用Kind快速模拟多节点K8s环境"
date: 2021-01-21T16:24:10+08:00
draft: false
tags: ["K8s"]
categories: ["K8s"]
featuredImagePreview: ""
summary: 在很多开发自测的场景中，我们需要一个干净且可折腾的K8s环境，比如要给节点打污点、开启K8s特性开关、做一些调度功能验证等,本文将介绍使用Kind快速搭建K8s多节点测试环境的方法。
---

> 在很多开发自测的场景中，我们需要一个干净且可折腾的K8s环境，比如要给节点打污点、开启K8s特性开关、做一些调度功能验证等。但搭建真实的K8s多节点环境耗费资源且繁琐，因此社区推出了一些工具帮助我们搭建K8s测试环境，比如Minikube、Kind等。经过实际使用，Kind是最快的支持模拟K8s多节点环境的部署工具，本文将介绍使用Kind快速搭建K8s多节点测试环境的方法。

## Kind简介

Kind是"Kubernetes in Docker"的简写，即使用Docker容器运行本地K8s集群的工具，它将K8s所需要的所有组件，全部部署在一个 `Docker` 容器中，可以非常方便快速地搭建K8s集群。与Minikube等传统工具相比，Kind最大的优势就是它极简的依赖项：只依赖于Docker。

Kind可以支持：

- 快速创建单个或多个K8s集群
- 支持离线部署多节点K8s集群
- 支持部署高可用的K8s集群

## Kind工作原理

Kind 使用容器来模拟每一个K8s节点，并在容器里面运行 `Systemd`。 容器里的 `Systemd` 托管了 `Kubelet` 和 `Containerd`，然后容器内部的 `Kubelet` 把其它K8s组件：`Kube-Apiserver`、`Etcd`、`CNI` 等等组件运行起来。

Kind内部使用了 `Kubeadm` 这个工具来做集群的部署，包括高可用集群也是借助 `Kubeadm` 提供的特性来完成的。在高用集群下还会额外部署了一个 Nginx 来提供负载均衡 VIP。

## Kind安装与基本使用

这里默认本机环境已经安装好了Docker，安装Docker的安装文档可直接参考官方文档：https://docs.docker.com/get-docker/

如果要通过命令行与K8s进行交互，需要安装`kubectl`，安装方法可参考：https://kubernetes.io/docs/tasks/tools/#install-kubectl

下面介绍在Linux环境下通过Kind二进制文件的安装方式，首先下载二进制并移动到PATH路径中

```shell
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-amd64
chmod +x ./kind
mv ./kind /some-dir-in-your-PATH/kind
```

最简单的搭建命令

```shell
$ kind create cluster
Creating cluster "kind" ...
 ✓ Ensuring node image (kindest/node:v1.19.1) 🖼
 ✓ Preparing nodes 📦
 ✓ Creating kubeadm config 📜
 ✓ Starting control-plane 🕹️
Cluster creation complete. You can now use the cluster with:

export KUBECONFIG="$(kind get kubeconfig-path --name="kind")"
kubectl cluster-info
```

默认创建出来的K8s集群名为`kind`，安装完成后的末尾会提示修改`KUBECONFIG`环境变量，指定`kubectl`访问该Kind K8s集群。

如果创建了多个K8s集群，可以使用`kubectl cluster-info --context`进行交互指定。

我个人使用Kind的理由是因为它能最快地模拟一个K8s多节点环境，下面介绍模拟多节点的Kind使用方法。

## 模拟K8s多节点环境

我个人使用Kind的理由是因为它能最快地模拟一个K8s多节点环境，下面介绍模拟多节点的Kind使用方法。

默认安装的集群只部署了一个控制节点，如果需要部署多节点集群，我们可以通过配置文件的方式来创建多个容器来模拟多个节点。使用Kind命令创建集群的时候，支持通过 `--config` 参数传递配置文件给 `Kind`，配置文件可修改的内容主要有 role 和 节点使用的镜像。例如：

```yaml
# a cluster with 3 control-plane nodes and 3 workers
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  FeatureGateName: true
nodes:
- role: control-plane
- role: control-plane
- role: control-plane
- role: worker
	image: kindest/node:v1.16.4@sha256:b91a2c2317a000f3a783489dfb755064177dbc3a0b2f4147d50f04825d016f55
- role: worker
  image: kindest/node:v1.16.4@sha256:b91a2c2317a000f3a783489dfb755064177dbc3a0b2f4147d50f04825d016f55
- role: worker
  image: kindest/node:v1.16.4@sha256:b91a2c2317a000f3a783489dfb755064177dbc3a0b2f4147d50f04825d016f55
```

然后使用上述配置文件创建Kind集群

```shell
kind create cluster --config kind-cluster.yaml
```

创建完成后，使用`kubectl get no`就可以看到多节点K8s集群了。

实际使用时我们要需要把本地的Docker镜像导入到模拟的K8s集群中，命令如下

```shell
kind load docker-image my-custom-image-0 my-custom-image-1
```

