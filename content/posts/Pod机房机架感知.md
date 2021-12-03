---
title: "Pod机房/机架感知"
date: 2021-08-11T09:38:03+08:00
draft: true
typora-root-url: ../../static
---

相关issues

- https://github.com/kubernetes/kubernetes/issues/40610

- https://stackoverflow.com/questions/36690446/inject-node-labels-into-kubernetes-pod

- https://github.com/kubernetes/kubernetes/issues/62078

- 目前的解决办法：https://gmaslowski.com/kubernetes-node-label-to-pod/

- ```shell
  "ZONE=$(kubectl get node $NODE_NAME -o json | jq -r '.metadata.labels[\"failure-domain.beta.kubernetes.io/zone\"]') \
                 CONFIG_FILE=/usr/share/elasticsearch/config/elasticsearch.yml \
                 CONFIG_FILE_BACKUP=/usr/share/elasticsearch/config/elasticsearch.yml.backup; \
                 mv $CONFIG_FILE $CONFIG_FILE_BACKUP && \
                 cat $CONFIG_FILE_BACKUP <(echo node.attr.zone: $ZONE) > $CONFIG_FILE"
  ```

- ```shell
  kubectl get no node1 -o jsonpath='{.metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}'
  ```