provider "aws" {
    region = "${var.region}"
}

# VPC and basic networking
resource "aws_vpc" "ds-harness-vpc" {
    cidr_block = "192.168.16.0/24"
    enable_dns_hostnames = true
    tags {
        Name = "ds-harness-vpc"
    }
}

resource "aws_internet_gateway" "ds-harness-vpc-igw" {
    vpc_id = "${aws_vpc.ds-harness-vpc.id}"
    tags {
        Name = "ds-harness-vpc-igw"
    }
}

resource "aws_subnet" "ds-harness-vpc-subnet-1" {
    vpc_id = "${aws_vpc.ds-harness-vpc.id}"
    cidr_block = "192.168.16.0/25"
    availability_zone = "${var.region_subnet_1}"

    tags {
        Name = "ds-harness-vpc-subnet-1"
    }
}

resource "aws_subnet" "ds-harness-vpc-subnet-2" {
    vpc_id = "${aws_vpc.ds-harness-vpc.id}"
    cidr_block = "192.168.16.128/25"
    availability_zone = "${var.region_subnet_2}"

    tags {
        Name = "ds-harness-vpc-subnet-2"
    }
}

resource "aws_route_table" "ds-harness-vpc-outbound" {
    vpc_id = "${aws_vpc.ds-harness-vpc.id}"
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = "${aws_internet_gateway.ds-harness-vpc-igw.id}"
    }

    tags {
        Name = "ds-harness-vpc-default-route"
    }
}

resource "aws_route_table_association" "ds-harness-vpc-subnet-1-routing" {
    subnet_id = "${aws_subnet.ds-harness-vpc-subnet-1.id}"
    route_table_id = "${aws_route_table.ds-harness-vpc-outbound.id}"
}

resource "aws_route_table_association" "ds-harness-vpc-subnet-2-routing" {
    subnet_id = "${aws_subnet.ds-harness-vpc-subnet-2.id}"
    route_table_id = "${aws_route_table.ds-harness-vpc-outbound.id}"
}

# We're standing up Windows boxes, so allow port 3389 (RDP) inbound
# as well as 5985-5986
resource "aws_security_group" "ds-harness-vpc-windowsboxes-sg" {
    name = "ds-harness-vpc-windowsboxes-sg"
    description = "RDP and WinRM ingress from anywhere"
    vpc_id = "${aws_vpc.ds-harness-vpc.id}"
}

resource "aws_security_group_rule" "ds-harness-vpc-ingress-rdp" {
    type = "ingress"
    from_port = 3389
    to_port = 3389
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    security_group_id = "${aws_security_group.ds-harness-vpc-windowsboxes-sg.id}"
}

resource "aws_security_group_rule" "ds-harness-vpc-ingress-winrm" {
    type = "ingress"
    from_port = 5985
    to_port = 5986
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    security_group_id = "${aws_security_group.ds-harness-vpc-windowsboxes-sg.id}"
}

# The directory itself
resource "aws_directory_service_directory" "ds-harness-directory" {
    name = "${var.directory_dn}"
    password = "${var.directory_password}"
    type = "SimpleAD"
    size = "Small"
    vpc_settings {
      vpc_id = "${aws_vpc.ds-harness-vpc.id}"
      subnet_ids = ["${aws_subnet.ds-harness-vpc-subnet-1.id}", "${aws_subnet.ds-harness-vpc-subnet-2.id}"]
   }
}

# The instance needs to have a role (with policy provided by AWS)
# to be able to self-domain-join
resource "aws_iam_role" "ds-harness-ssm-instance-role" {
    name = "ds-harness-ssm-instance-role"
    path = "/"
    assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ds-harness-ssm-instance-role-attach" {
    role = "${aws_iam_role.ds-harness-ssm-instance-role.name}"
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_instance_profile" "ds-harness-ssm-instance-profile" {
    name = "ds-harness-ssm-instance-profile"
    roles = ["${aws_iam_role.ds-harness-ssm-instance-role.name}"]
}

# The Windows management node
data "aws_ami" "windows2016" {
  most_recent = true
  filter {
    name = "name"
    values = ["Windows_Server-2016-English-Full-Base-*"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name = "platform"
    values = ["windows"]
  }
  owners = ["amazon"]
}

resource "aws_ssm_document" "dsadmin-domainjoin" {
  name    = "dsadmin-domainjoin",
  content = <<DOC
{
    "schemaVersion": "1.0",
    "description": "Domain Join Configuration",
    "runtimeConfig": {
      "aws:domainJoin": {
        "properties": {
          "directoryId": "${aws_directory_service_directory.ds-harness-directory.id}",
          "directoryName": "${var.directory_dn}",
          "dnsIpAddresses": ["${join("\",\"", aws_directory_service_directory.ds-harness-directory.dns_ip_addresses)}"]
        }
      }
    }
}
DOC
}

resource "aws_ssm_association" "dsadmin-domainjoin-ssmassoc" {
  name        = "dsadmin-domainjoin-ssmassoc",
  instance_id = "${aws_instance.dsadmin-server.id}"
}

resource "aws_instance" "dsadmin-server" {
    ami = "${data.aws_ami.windows2016.id}"
    instance_type = "${var.dsadmin_instance_size}"
    iam_instance_profile = "${aws_iam_instance_profile.ds-harness-ssm-instance-profile.id}"
    associate_public_ip_address = "true"
    tags {
        Name = "directory admin server"
    }
    subnet_id = "${aws_subnet.ds-harness-vpc-subnet-1.id}"
    vpc_security_group_ids = ["${aws_security_group.ds-harness-vpc-windowsboxes-sg.id}"]
    user_data = "<powershell>Add-WindowsFeature RSAT-AD-AdminCenter</powershell>"
}

# mark the foregoing as needing a public IP
# add directory_service resource
# join the dsdadmin to the domain
# need a role to be described

output "dsadmin-server" {
    value = "${aws_instance.dsadmin-server.public_dns}"
}
