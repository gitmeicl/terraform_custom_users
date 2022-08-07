terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.72.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "4.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.1.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.2.2"
    }
  }
  required_version = ">= 0.13"
}

provider "random" {
  # Configuration options
}

resource "random_password" "password" {
  count            = length(var.devs)
  length           = 12
  special          = true
  override_special = "!#*_=+:?"
}

provider "yandex" {
  #token = var.service_token
  service_account_key_file = var.key_file
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}

#getting image_id for instance
data "yandex_compute_image" "my_image" {
  family = "ubuntu-2004-lts"
}

#getting subnet_id
data "yandex_vpc_subnet" "admin" {
  name = "default-${var.zone}"
}

resource "yandex_compute_instance" "default" {
  count = length(var.devs)
  name  = element(split("-", var.devs[count.index]), 1)
  zone  = var.zone
  labels = {
    task_name  = var.task
    user_email = var.mail
    module     = "devops"
  }

  metadata = {
    user-data = templatefile("metadata.tftpl", {
      name    = element(split("-", var.devs[count.index]), 1),
      admin   = var.my_ssh,
    })
  }

  resources {
    cores         = 2
    memory        = element(split("-", var.devs[count.index]), 0) == "proxy" ? 4 : 2
    core_fraction = element(split("-", var.devs[count.index]), 0) == "lb" ? 100 : 20
  }

  boot_disk {
    initialize_params {
      size     = element(split("-", var.devs[count.index]), 0) == "db" ? 30 : 25
      image_id = data.yandex_compute_image.my_image.id
    }
  }

  network_interface {
    subnet_id = data.yandex_vpc_subnet.admin.id
    nat       = true
  }

  connection {
    type        = "ssh"
    host        = self.network_interface.0.nat_ip_address
    user        = element(split("-", var.devs[count.index]), 1)
    private_key = file(var.private_ssh)
  }

  provisioner "remote-exec" {
    inline = [
      "echo ${element(split("-", var.devs[count.index]), 1)}:${random_password.password[count.index].result} | sudo chpasswd"
    ]
    on_failure = continue
  }
}

provider "aws" {
  # Configuration options
  access_key = var.access_key
  secret_key = var.secret_key
  region     = "eu-central-1"
}


data "aws_route53_zone" "primary" {
  name = var.domain_name
}

resource "aws_route53_record" "asd" {
  count   = length(var.devs)
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = format("%s-%s", element(split("-", var.devs[count.index]), 1), element(split("-", var.devs[count.index]), 0))
  type    = "A"
  ttl     = "300"
  records = [yandex_compute_instance.default[count.index].network_interface.0.nat_ip_address]
}

provider "local" {
  # Configuration options
}

resource "local_file" "out" {
  content = templatefile("output.tftpl", {
    element  = length(var.devs),
    domain   = aws_route53_record.asd[*].fqdn,
    ip       = yandex_compute_instance.default[*].network_interface.0.nat_ip_address,
    password = random_password.password[*].result
  })
  filename = "output.txt"
}
