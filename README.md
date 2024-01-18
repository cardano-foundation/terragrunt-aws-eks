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

# Destroying everything

Given that our `tg-modules` generate JSON outputs that are passed as inputs to other modules, it can be tricky to destroy all the resources if there is some problem while destroying the modules altogether. For example, it might be the case that the `eks-alb` module failed to deregister some target group and when you retry to destroy it, the `eks` module itself is already destroyed so there is no input JSON to pass to `eks-alb` anymore.

Since at this point where we want to destroy everything we don't care about inconsistencies on the plan, we can workaround the problem described below by saving the JSON I/Os with `terragrunt` and providing them so the destroy command won't complain. This can be accomplished by following the next steps:

* Executing a `terragrunt run-all plan` like this:
```
terragrunt run-all plan \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive \
  --terragrunt-debug
```
* Copying the most complete (the one including more input jsons, which is the `eks-alb` one) vars file to every `tg-module` so it's picked as an input tfvars file:
```
for tgm in tg-modules/*
do
    cp -a tg-modules/eks-alb/terragrunt-debug.tfvars.json $tgm/terraform.tfvars.json
done
```
* Executing the destroy-all command from the `environment/$ENV` dir or executing them from each tg-module dir independently:
```
terragrunt run-all destroy \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive
```
* And last but not least, cleaning up the folders with: 
```
rm -f tg-modules/*/terraform.tfvars.json
```

# Misc ops

## Get kubeconfig for specific cluster

```
export AWS_REGION=eu-west-1
aws eks list-clusters --region ${AWS_REGION}
# set cluster name from list above
export CLUSTER_NAME=dev-example-com-cluster
aws eks update-kubeconfig \
  --region ${AWS_REGION} \
  --name ${CLUSTER_NAME} \
  --kubeconfig ~/.kube/${CLUSTER_NAME}-${AWS_REGION}.yaml
```
