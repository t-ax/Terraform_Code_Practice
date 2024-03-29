#Get Linux AMI ID using SSM Parameter endpoint in us-east-1
data "aws_ssm_parameter" "linuxAmi" {
    provider = aws.region-master
    name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

#Get Linux AMI ID using SSM Parameter endpoint in us-west-2
data "aws_ssm_parameter" "linuxAmi-west" {
    provider = aws.region-worker
    name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

#Create key-pair for logging into EC2 in us-east-1
resource "aws_key_pair" "master-key" {
  provider   = aws.region-master
  key_name   = "jenkins"
  public_key = file("~/.ssh/id_rsa.pub")
}

#Create key-pair for logging into EC2 in us-west-2
resource "aws_key_pair" "worker-key" {
  provider   = aws.region-worker
  key_name   = "jenkins"
  public_key = file("~/.ssh/id_rsa.pub")
}

#Create and bootstrap EC2 in us-east-1
resource "aws_instance" "jenkins-master" {
    provider = aws.region-master
    ami = data.aws_ssm_parameter.linuxAmi.value
    key_name = aws_key_pair.master-key.key_name
    associate_public_ip_address = true
    instance_type = var.instance_type
    security_groups = [aws_security_group.jenkins-sg.id]
    subnet_id = aws_subnet.subnet_1.id

    tags = {
        Name = "jenkins_master_tf"
    }

    depends_on = [aws_main_route_table_association.set-master-default-rt-assoc]

    provisioner "local-exec" {
        command = <<EOF
            aws --profile ${var.profile} ec2 wait instance-status-ok --region ${var.region-master} --instance-ids ${self.id}
            ansible-playbook --extra-vars 'passed_in_hosts=tag_Name_${self.tags.Name}' ansible_templates/inventory_aws/install-jenkins-master.yaml
        EOF
    }


}

#Create and bootstrap EC2 in us-east-1
resource "aws_instance" "jenkins-worker" {
    provider = aws.region-worker
    count = var.workers-count
    ami = data.aws_ssm_parameter.linuxAmi-west.value
    key_name = aws_key_pair.worker-key.key_name
    associate_public_ip_address = true
    instance_type = var.instance_type
    security_groups = [aws_security_group.jenkins-sg-west.id]
    subnet_id = aws_subnet.subnet_1_west.id

    tags = {
        Name = join("_", ["jenkins_worker_tf", count.index + 1])
    }

    depends_on = [aws_main_route_table_association.set-worker-default-rt-assoc, aws_instance.jenkins-master]

    provisioner "local-exec" {
        command = <<EOF
            aws --profile ${var.profile} ec2 wait instance-status-ok --region ${var.region-worker} --instance-ids ${self.id}
            ansible-playbook --extra-vars 'passed_in_hosts=tag_Name_${self.tags.Name} master_ip=${aws_instance.jenkins-master.private_ip}' ansible_templates/inventory_aws/install-jenkins-worker.yaml
        EOF
    }

    provisioner "remote-exec" {
        when = destroy
        inline = [
            "java -jar /home/ec2-user/jenkins-cli.jar -auth @/home/ec2-user/jenkins_auth -s http://${aws_instance.jenkins-master.private_ip}:8080 delete-node ${self.private_ip}"
        ]
        connection {
            type = "ssh"
            user = "ec2-user"
            private_key = file("~/.ssh/id_rsa")
            host = self.public_ip
        }
    }
}