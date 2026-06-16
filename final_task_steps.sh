sudo chown user:user /opt/

mkdir -p /opt/dev /opt/prod /opt/modules
mkdir -p /opt/modules/vpc /opt/modules/security_groups /opt/modules/db /opt/modules/vm

cat > /opt/modules/vpc/main.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
}

resource "yandex_vpc_network" "this" {
  name = "vpc-${var.username}-${var.environment}"
}

resource "yandex_vpc_subnet" "public" {
  name           = "subnet-public-${var.username}-${var.environment}"
  network_id     = yandex_vpc_network.this.id
  zone           = var.zone
  v4_cidr_blocks = ["192.168.10.0/24"]
}

resource "yandex_vpc_subnet" "private" {
  name           = "subnet-private-${var.username}-${var.environment}"
  network_id     = yandex_vpc_network.this.id
  zone           = var.zone
  v4_cidr_blocks = ["192.168.20.0/24"]
}
EOF

cat > /opt/modules/vpc/outputs.tf << 'EOF'
output "network_id" {
  value = yandex_vpc_network.this.id
}

output "public_subnet_id" {
  value = yandex_vpc_subnet.public.id
}

output "private_subnet_id" {
  value = yandex_vpc_subnet.private.id
}

output "public_subnet_cidr" {
  value = yandex_vpc_subnet.public.v4_cidr_blocks
}
EOF

cat > /opt/modules/vpc/variables.tf << 'EOF'
variable "username" {
  type = string
}

variable "environment" {
  type = string
}

variable "zone" {
  type    = string
  default = "ru-central1-d"
}
EOF

cat > /opt/modules/db/main.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
}

resource "yandex_mdb_mysql_cluster" "this" {
  name        = "mysql-${var.username}-${var.environment}"
  environment = var.environment == "prod" ? "PRODUCTION" : "PRESTABLE"
  network_id  = var.network_id
  version     = "8.0"

  resources {
    resource_preset_id = var.environment == "prod" ? "s2.small" : "s2.micro"
    disk_type_id       = "network-ssd"
    disk_size          = var.environment == "prod" ? 20 : 10
  }

  host {
    zone      = var.zone
    subnet_id = var.subnet_id
  }
}

resource "yandex_mdb_mysql_database" "this" {
  cluster_id = yandex_mdb_mysql_cluster.this.id
  name       = "wordpress"
}

resource "yandex_mdb_mysql_user" "this" {
  cluster_id = yandex_mdb_mysql_cluster.this.id
  name       = "wpuser"
  password   = var.db_password

  permission {
    database_name = yandex_mdb_mysql_database.this.name
    roles         = ["ALL"]
  }
}
EOF

cat > /opt/modules/db/outputs.tf << 'EOF'
output "database_name" {
  value = yandex_mdb_mysql_database.this.name
}

output "user_name" {
  value = yandex_mdb_mysql_user.this.name
}

output "host_fqdn" {
  value = yandex_mdb_mysql_cluster.this.host[0].fqdn
}
EOF

cat > /opt/modules/db/variables.tf << 'EOF'
variable "username" {
  type = string
}

variable "environment" {
  type = string
}

variable "network_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "zone" {
  type    = string
  default = "ru-central1-d"
}

variable "db_password" {
  type      = string
  sensitive = true
}
EOF

cat > /opt/modules/security_groups/main.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
}

resource "yandex_vpc_security_group" "vm_sg" {
  name        = "sg-${var.username}-${var.environment}-vm"
  description = "Security group for VM"
  network_id  = var.network_id

  ingress {
    protocol       = "TCP"
    description    = "HTTP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    description    = "HTTPS"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  dynamic "ingress" {
    for_each = var.environment == "dev" ? [1] : []
    content {
      protocol       = "TCP"
      description    = "SSH"
      v4_cidr_blocks = ["0.0.0.0/0"]
      port           = 22
    }
  }

  egress {
    protocol       = "ANY"
    description    = "Allow all egress"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "db_sg" {
  name        = "sg-${var.username}-${var.environment}-db"
  description = "Security group for Database"
  network_id  = var.network_id

  ingress {
    protocol       = "TCP"
    description    = "MySQL from VM subnet"
    v4_cidr_blocks = [var.vm_subnet_cidr]
    port           = 3306
  }

  egress {
    protocol       = "ANY"
    description    = "Allow all egress"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
EOF

cat > /opt/modules/security_groups/outputs.tf << 'EOF'
output "vm_security_group_id" {
  value = yandex_vpc_security_group.vm_sg.id
}

output "db_security_group_id" {
  value = yandex_vpc_security_group.db_sg.id
}
EOF

cat > /opt/modules/security_groups/variables.tf << 'EOF'
variable "username" {
  type = string
}

variable "environment" {
  type = string
}

variable "network_id" {
  type = string
}

variable "vm_subnet_cidr" {
  type = string
}
EOF

cat > /opt/modules/vm/cloud-init.tpl << 'EOF'
#!/bin/bash
set -e

apt-get update
apt-get install -y nginx php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-xmlrpc wget unzip

cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mkdir -p /var/www/html
cp -r wordpress/* /var/www/html/
chown -R www-data:www-data /var/www/html/

cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
sed -i "s/database_name_here/${db_name}/g" /var/www/html/wp-config.php
sed -i "s/username_here/${db_user}/g" /var/www/html/wp-config.php
sed -i "s/password_here/${db_password}/g" /var/www/html/wp-config.php
sed -i "s/localhost/${db_host}/g" /var/www/html/wp-config.php

curl -s https://api.wordpress.org/secret-key/1.1/salt/ > /tmp/salts
sed -i '/AUTH_KEY/d' /var/www/html/wp-config.php
sed -i '/SECURE_AUTH_KEY/d' /var/www/html/wp-config.php
sed -i '/LOGGED_IN_KEY/d' /var/www/html/wp-config.php
sed -i '/NONCE_KEY/d' /var/www/html/wp-config.php
sed -i '/AUTH_SALT/d' /var/www/html/wp-config.php
sed -i '/SECURE_AUTH_SALT/d' /var/www/html/wp-config.php
sed -i '/LOGGED_IN_SALT/d' /var/www/html/wp-config.php
sed -i '/NONCE_SALT/d' /var/www/html/wp-config.php
sed -i "/define('AUTH_KEY'/r /tmp/salts" /var/www/html/wp-config.php

cat > /etc/nginx/sites-available/wordpress << 'NGINX'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

systemctl restart nginx || true
systemctl restart php8.1-fpm || true

echo "WordPress installation completed!"
EOF

cat > /opt/modules/vm/main.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
}

resource "yandex_compute_instance" "this" {
  name        = "vm-${var.username}-${var.environment}"
  platform_id = "standard-v2"
  zone        = var.zone

  resources {
    cores         = var.cpu
    memory        = var.ram
    core_fraction = var.environment == "prod" ? 100 : 50
  }

  boot_disk {
    initialize_params {
      image_id = "fd8hrphlcsmi293sjc74"  # Ubuntu 22.04
      size     = 20
    }
  }

  network_interface {
    subnet_id          = var.public_subnet_id
    security_group_ids = [var.vm_security_group_id]
    nat                = true
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.tpl", {
      db_host     = var.db_host
      db_name     = var.db_name
      db_user     = var.db_user
      db_password = var.db_password
    })
  }
}
EOF

cat > /opt/modules/vm/outputs.tf << 'EOF'
output "public_ip" {
  value = yandex_compute_instance.this.network_interface[0].nat_ip_address
}
EOF

cat > /opt/modules/vm/variables.tf << 'EOF'
variable "username" {
  type = string
}

variable "environment" {
  type = string
}

variable "zone" {
  type    = string
  default = "ru-central1-d"
}

variable "cpu" {
  type = number
}

variable "ram" {
  type = number
}

variable "public_subnet_id" {
  type = string
}

variable "vm_security_group_id" {
  type = string
}

variable "db_host" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}
EOF

cat > /opt/dev/main.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      version = "~> 0.139.0"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "yandex" {
  service_account_key_file = "/opt/authorized_key.json"
  cloud_id                 = "b1g194thq1f5sstpfb1r"
  folder_id                = "b1g9k1ints1npj40g344"
  zone                     = "ru-central1-d"
}

module "vpc" {
  source      = "../modules/vpc"
  username    = "ayakurnov1982"
  environment = "dev"
}

module "security_groups" {
  source         = "../modules/security_groups"
  username       = "ayakurnov1982"
  environment    = "dev"
  network_id     = module.vpc.network_id
  vm_subnet_cidr = module.vpc.public_subnet_cidr[0]
}

module "db" {
  source      = "../modules/db"
  username    = "ayakurnov1982"
  environment = "dev"
  network_id  = module.vpc.network_id
  subnet_id   = module.vpc.private_subnet_id
  db_password = var.db_password
}

module "vm" {
  source               = "../modules/vm"
  username             = "ayakurnov1982"
  environment          = "dev"
  cpu                  = 2
  ram                  = 2
  public_subnet_id     = module.vpc.public_subnet_id
  vm_security_group_id = module.security_groups.vm_security_group_id
  db_host              = module.db.host_fqdn
  db_name              = module.db.database_name
  db_user              = module.db.user_name
  db_password          = var.db_password
}

resource "null_resource" "save_ip" {
  depends_on = [module.vm]
  
  provisioner "local-exec" {
    command = "echo ${module.vm.public_ip} > /opt/ip.txt"
  }
}
EOF

cat > /opt/dev/outputs.tf << 'EOF'
output "dev_instance_ip" {
  value = module.vm.public_ip
}
EOF

cat > /opt/dev/variables.tf << 'EOF'
variable "db_password" {
  type      = string
  sensitive = true
}
EOF

cat > /opt/dev/terraform.tfvars << 'EOF'
db_password = "SecurePass123!"
EOF

cat > /opt/prod/main.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      version = "~> 0.139.0"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "yandex" {
  service_account_key_file = "/opt/authorized_key.json"
  cloud_id                 = "b1g194thq1f5sstpfb1r"
  folder_id                = "b1g9k1ints1npj40g344"
  zone                     = "ru-central1-d"
}

module "vpc" {
  source      = "../modules/vpc"
  username    = "ayakurnov1982"
  environment = "prod"
}

module "security_groups" {
  source         = "../modules/security_groups"
  username       = "ayakurnov1982"
  environment    = "prod"
  network_id     = module.vpc.network_id
  vm_subnet_cidr = module.vpc.public_subnet_cidr[0]
}

module "db" {
  source      = "../modules/db"
  username    = "ayakurnov1982"
  environment = "prod"
  network_id  = module.vpc.network_id
  subnet_id   = module.vpc.private_subnet_id
  db_password = var.db_password
}

module "vm" {
  source               = "../modules/vm"
  username             = "ayakurnov1982"
  environment          = "prod"
  cpu                  = 2
  ram                  = 4
  public_subnet_id     = module.vpc.public_subnet_id
  vm_security_group_id = module.security_groups.vm_security_group_id
  db_host              = module.db.host_fqdn
  db_name              = module.db.database_name
  db_user              = module.db.user_name
  db_password          = var.db_password
}

resource "null_resource" "save_ip" {
  depends_on = [module.vm]
  
  provisioner "local-exec" {
    command = "echo ${module.vm.public_ip} >> /opt/ip.txt"
  }
}
EOF

cat > /opt/prod/outputs.tf << 'EOF'
output "prod_instance_ip" {
  value = module.vm.public_ip
}
EOF

cat > /opt/prod/variables.tf << 'EOF'
variable "db_password" {
  type      = string
  sensitive = true
}
EOF

cat > /opt/prod/terraform.tfvars << 'EOF'
db_password = "SecurePass123!PROD"
EOF

cat > /opt/versions.tf << 'EOF'
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      version = "~> 0.139.0"
    }
  }
}
EOF







cd /opt/dev
terraform init
terraform plan
terraform apply  -auto-approve

terraform destroy -auto-approve
