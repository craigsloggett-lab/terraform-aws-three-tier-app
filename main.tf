data "aws_ami" "selected" {
  most_recent = true
  owners      = var.ami.owners

  filter {
    name   = "name"
    values = [var.ami.name_pattern]
  }
}
