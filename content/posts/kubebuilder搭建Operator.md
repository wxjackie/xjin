---
title: "Kubebuilder搭建Operator"
date: 2021-08-11T09:38:03+08:00
draft: true
typora-root-url: ../../static
---

## 步骤

### 命令流程

```shell
# 创建一个空文件夹
mkdir example-operator
# go module初始化
go mod init xjin.wang/example-operator
# kubebuidler初始化工程
kubebuilder init --domain netease.com
# kubebuilder创建API对象
kubebuilder create api --group ncr --version v1alpha1 --kind DataSync
# 调整types.go，定义CR对象的Spec信息后，重新生成CRD yaml和object通用代码
make manifests generate
```



