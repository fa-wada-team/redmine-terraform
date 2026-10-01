provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Project   = var.project
        ManagedBy = "terraform"
      },
      var.tags,
    )
  }
}
