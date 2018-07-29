# Backend <<<<< change region >>>>>
terraform {
  backend "s3" {
    bucket = "tf-state-evpn-instance"
    key    = "terraform.tfstat"
    region = "us-east-1"
  }
}

variable "region" {
  default = "us-east-1"
}

provider "aws" {
  region = "${var.region}"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "ec2Dev"
  cidr = "100.70.8.0/24"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets = ["100.70.8.0/27", "100.70.8.32/27"]
  private_subnets  = ["100.70.8.128/27", "100.70.8.160/27"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}


variable "AMIImage" {
  type = "map"
  default = {
    us-east-1 = "ami-b73b63a0"
    us-west-2 = "ami-5ec1673e"
  }
  description = "Add more region as needed"
}

resource "aws_key_pair" "key-opsdev-evpn" {
  key_name   = "key-opsdev-evpn"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAB3iDd/bSlAd2L8PPLSwSHp7/aY8MFIX56EJCYY1QtapozzVoaG+K+tMT6hYwLNHlnBRvmh89IPyIhyZddK/qUdBrY9UpxnJlwlyiTyuPdYeR8qxbCFgP8v6tlxmxH/wmVuSf7e9gYYRyzZqwL4c0x1x71kB2gLHV2pQfhks5YAN8Lopu4HA57H0lI1c0wSH7yKfvRGTi/ncnqtbLoLF4McsiLai8cvU7zI0TkRqiqooQVsdKBhTQ2t1ZqSUbkUSw9k51hvR1ZTPBwgaInpKZjhLEqp5TKkk4KZrBZroXmuyRMGYRaW/UPCmf35JyGbncw7LaYMxb5Z/h/77wBBFf dev@dev"
}

resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow inbound ssh"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress {
    from_port   = 0
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

resource "aws_network_interface" "svpn1_eth1" {
  subnet_id       = "${module.vpc.private_subnets[0]}"

  attachment {
    instance     = "${aws_instance.svpn1.id}"
    device_index = 1
  }
}

resource "aws_network_interface" "svpn2_eth1" {
  subnet_id       = "${module.vpc.private_subnets[1]}"

  attachment {
    instance     = "${aws_instance.svpn2.id}"
    device_index = 1
  }
}


resource "aws_instance" "hvpn" {
  ami           = "${lookup(var.AMIImage, var.region)}"
  instance_type = "t2.micro"
  associate_public_ip_address = "true"
  subnet_id = "${module.vpc.public_subnets[0]}"
  vpc_security_group_ids = ["${module.vpc.default_security_group_id}","${aws_security_group.allow_ssh.id}"]
  key_name = "${aws_key_pair.key-opsdev-evpn.key_name}"
  tags {
        Name = "hvpn"
  }
  user_data = <<HEREDOC
    #!/bin/bash
    yum update -y
    yum -y install bridge-utils
    echo "Set up local ip address"
    ip addr add dev eth0 10.0.0.1/24
    ip link set eth1 up
    echo "Set up mGRE tunnel"
    ip link add tunnel1 type gre remote any local 10.0.0.1
    ip addr add dev tunnel1 10.10.10.1/24
    ip link set tunnel1 up
    echo "Set up Vxlan tunnel"
    ip link add tunnel2 type vxlan remote 0.0.0.0 local 10.0.0.1 external learning
    ip link set tunnel2 up
    echo "Set up bridge"
    brctl addbr br-vxlan
    ip link set br-vxlan up
    brctl addif br-vxlan tunnel2
    brctl hairpin br-vxlan tunnel2 on
    echo "Done!"
  HEREDOC
}

resource "aws_instance" "svpn1" {
  ami           = "${lookup(var.AMIImage, var.region)}"
  instance_type = "t2.micro"
  associate_public_ip_address = "true"
  subnet_id = "${module.vpc.public_subnets[0]}"
  vpc_security_group_ids = ["${module.vpc.default_security_group_id}","${aws_security_group.allow_ssh.id}"]
  key_name = "${aws_key_pair.key-opsdev-evpn.key_name}"
  tags {
        Name = "svpn1"
  }
  user_data = <<HEREDOC
    #!/bin/bash
    yum update -y
    yum -y install bridge-utils
    echo "Set up local ip address"
    ip addr add dev eth0 10.0.0.2/24
    ip link set eth0 up
    echo "Set up GRE tunnel"
    ip link add name tunnel1 type gre remote 10.0.0.1 local 10.0.0.2
    ip link set tunnel1 up
    ip addr add dev tunnel1 10.10.10.2/24
    echo "Set up Vxlan tunnel"
    ip link add name tunnel2 type vxlan id 100 remote 10.0.0.1 local 10.0.0.2 l2miss nolearning
    ip link set tunnel2 up
    echo "Set up interface to host"
    ip link set eth1 up
    echo "Set up bridge"
    brctl addbr br-vxlan
    ip link set br-vxlan up
    echo "Add interface to bridge"
    brctl addif br-vxlan eth2 tunnel2
    bridge fdb del 00:00:00:00:00:00 dev tunnel2
    echo "Set up broadcast forwarding"
    bridge fdb add ff:ff:ff:ff:ff:ff dev tunnel2 dst 10.0.0.1 vni 100
    echo "Set up OpenNHRP config"
    echo "interface tunnel1\n
    vpn-id 1\n
    map-vni 100 10.10.10.1 2e:11:11:11:11:11 register\n
    interface tunnel2\n
    vpn-id 1\n
    default-vni 100 10.0.0.1\n
    controller tunnel1\n
    interface br-vxlan\n
    vpn-id 1"
    echo "Done!"
  HEREDOC
}

resource "aws_instance" "svpn2" {
  ami           = "${lookup(var.AMIImage, var.region)}"
  instance_type = "t2.micro"
  associate_public_ip_address = "true"
  subnet_id = "${module.vpc.public_subnets[0]}"
  vpc_security_group_ids = ["${module.vpc.default_security_group_id}","${aws_security_group.allow_ssh.id}"]
  key_name = "${aws_key_pair.key-opsdev-evpn.key_name}"
  tags {
        Name = "svpn2"
  }
  user_data = <<HEREDOC
    #!/bin/bash
    yum update -y
    yum -y install bridge-utils
    echo "Set up local ip address"
    ip addr add dev eth0 10.0.0.2/24
    ip link set eth0 up
    echo "Set up GRE tunnel"
    ip link add name tunnel1 type gre remote 10.0.0.1 local 10.0.0.2
    ip link set tunnel1 up
    ip addr add dev tunnel1 10.10.10.2/24
    echo "Set up Vxlan tunnel"
    ip link add name tunnel2 type vxlan id 100 remote 10.0.0.1 local 10.0.0.2 l2miss nolearning
    ip link set tunnel2 up
    echo "Set up interface to host"
    ip link set eth1 up
    echo "Set up bridge"
    brctl addbr br-vxlan
    ip link set br-vxlan up
    echo "Add interface to bridge"
    brctl addif br-vxlan eth2 tunnel2
    bridge fdb del 00:00:00:00:00:00 dev tunnel2
    echo "Set up broadcast forwarding"
    bridge fdb add ff:ff:ff:ff:ff:ff dev tunnel2 dst 10.0.0.1 vni 100
    echo "Set up OpenNHRP config"
    echo "interface tunnel1\n
    vpn-id 1\n
    map-vni 100 10.10.10.1 2e:11:11:11:11:11 register\n
    interface tunnel2\n
    vpn-id 1\n
    default-vni 100 10.0.0.1\n
    controller tunnel1\n
    interface br-vxlan\n
    vpn-id 1"
    echo "Done!"
  HEREDOC
}

