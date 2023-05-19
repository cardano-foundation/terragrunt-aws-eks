# How to deploy new environments

* Set the environment to use:
```
export ENVIRONMENT_NAME=production # must match any folder in ./environments
export AWS_PROFILE=xxx             # must match a profile in ~/.aws/config
```
* Copy the template environment (or any other) `./environments/dev-example-com` to `./environments/${ENVIRONMENT_NAME}`:
```
cp -a environments/dev-example-com environments/${ENVIRONMENT_NAME}
```
* Customize the variables in `./environments/${ENVIRONMENT_NAME}/config.yaml`. By the moment, the only available doc for it is in the form of comments within this file.
* Login to the AWS account if needed:
```
aws sso login --profile $AWS_PROFILE
```
* Run `terragrunt` from the corresponding environment folder. It will create the tfstate backend services out the box (s3/dynamodb):
```
cd environments/${ENVIRONMENT_NAME}

terragrunt run-all plan \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive
```
* Eventually, apply the plan:
```
terragrunt run-all apply \
  --terragrunt-include-external-dependencies
```

# Switching between environments

Everything you need to do is to run a terraform reconfigure before being able to plan/apply a different environment:
```
cd environments/${ENVIRONMENT_NAME}
terragrunt run-all init -reconfigure \
  --terragrunt-include-external-dependencies
```

# Applying only specific modules

This terragrunt projects maintains separate, smaller, tfstates for each module that makes targeting resources quicker. Imagine you'd only want to plan/apply changes of an specific module like `route53`, for that you'd just set the `$ENVIRONMENT_NAME` you want to target and you'd go into the module directory and execute the plan, ie:

```
export ENVIRONMENT_NAME=whatever
cd tg-modules/route53
terragrunt init -reconfigure # This is important if you've used any other environment before
terragrunt plan
```

Optionally you can also target specific resources for the module just like you'd do with plain terraform by adding `-target=resource_type.resource_name`.
