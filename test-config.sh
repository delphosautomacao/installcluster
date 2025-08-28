#!/usr/bin/env bash
# Configuração de teste para instalação do Consul

export INSTALL_DOCKER="n"
export INSTALL_CONSUL="s"
export INSTALL_NOMAD="n"
export CONSUL_ADVERTISE_ADDR="192.168.0.101"
export CONSUL_BOOTSTRAP_EXPECT=1
export CONSUL_JOIN="n"
export CONSUL_SERVERS=""
export CONSUL_ENCRYPT_KEY=""