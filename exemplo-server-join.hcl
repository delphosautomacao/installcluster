# Exemplo de configuração Nomad com server_join
# Este é o formato que será gerado após a modificação

bind_addr = "10.0.1.10"
region    = "global"
datacenter= "dc1"
name      = "nomad-server-1"

data_dir  = "/opt/nomad/data"

# Integração com Consul
consul {
  address = "127.0.0.1:8500"
  server_service_name = "nomad"
  client_service_name = "nomad-client"
  auto_advertise = true
  server_auto_join = true
  client_auto_join = true
}

server {
  enabled          = true
  bootstrap_expect = 3

  server_join {
    retry_join     = ["10.0.1.10", "10.0.1.11", "10.0.1.12"]
    retry_max      = 3
    retry_interval = "15s"
  }
}

client {
  enabled = true
  servers = ["10.0.1.10", "10.0.1.11", "10.0.1.12"]
  
  # Configuração para montagens de alocações
  host_volume "alloc_mounts" {
    path = "/opt/alloc_mounts"
    read_only = false
  }
}

# Endurecimento leve (opcional)
acl {
  enabled = false
}