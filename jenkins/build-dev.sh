#!/bin/bash

# SHOULD BE DELETED BEFORE PUSHED TO JENKINS
#APP_HOSTNAME=my.app.com
#APP_NAME=myapp
#APP_GIT=https://github.com/rosoroki/storm-starter.git
#APP_GIT_REF=
#APP_GIT_CONTEXT_DIR=
DEV_USER_NAME=dev1
DEV_USER_PASSWD=dev1
QA_USER_NAME=test1
QA_USER_PASSWD=test1
OSE_SERVER=172.28.128.4:8443
DEVEL_PROJ_NAME=development
QA_PROJ_NAME=testing
AUX_TEMPLATE=storm
MAIN_TEMPLATE=storm-executor
REGISTRY_URL=fabric8-docker-registry.test.vagrant.f8

trap "exit 1" TERM
export TOP_PID=$$

# Create auxiliary deployment based on auxiliary template (see $AUX_TEMPLATE)
function create_aux_deployment {	
	echo "New auxiliary deployment will be started..." 
	oc new-app --template=${AUX_TEMPLATE}
	sleep 10
	
	exitfor=1
	attempts=75
	count=0
	while [ $exitfor -ne 0 -a $count -lt $attempts ]; do
		exitfor=0
		echo "Checking status of pods..."
		PODS=`oc get pods -o name -l template=${AUX_TEMPLATE}`
		if [ -z "$PODS" ]; then
			echo "No pods are scheduled..."
			exitfor=1
		else
			arr=( $PODS )
			for i in "${arr[@]}"; do
				status=`oc get $i --template '{{.status.phase}}'`
				echo "Pod $i is $status"
				if [[ $status == "Failed" || $status == "Error" || $status == "Canceled" ]]; then
					echo "Fail: resource $i start has completed with unsuccessful status: ${status}"
					kill -s TERM $TOP_PID
				fi
				if [ $status == "Pending" ]; then
					exitfor=1            	
				fi         
			done
		fi
		if [ $exitfor -ne 0 ]; then
			count=$(($count+1))
			echo "Attempt $count/$attempts"
			sleep 5
		fi	
	done;
	if [ $exitfor -ne 0 ]; then
		echo "Unabel to create aux deployment after maximum attempts"
		kill -s TERM $TOP_PID
	fi
}

# Delete auxiliary deployment created earlier from auxiliary template (see $AUX_TEMPLATE)
function delete_aux_deployment {
    echo "Current auxiliary deployment will be destroyed..." 
	oc delete all -l template=${AUX_TEMPLATE}
	sleep 10

	exitfor=1
	attempts=75
	count=0
	while [ $exitfor -ne 0 -a $count -lt $attempts ]; do
		RESOURCES=`oc get pods,svc,rc -o name -l template=${AUX_TEMPLATE}`
		if [ -z "$RESOURCES" ]; then
			echo " pods, svc, rc from template ${AUX_TEMPLATE} are deleted"
			exitfor=0
		else
			echo "Some resources from template ${AUX_TEMPLATE} are still in the system"
			count=$(($count+1))
			echo "Attempt $count/$attempts"
			unset RESOURCES
			sleep 5
		fi
	done;
	if [ $exitfor -ne 0 ]; then
		echo "Unabel to delete aux deployment after maximum attempts"
		kill -s TERM $TOP_PID
	fi	
}

function create_main_app {
	echo "New auxiliary deployment will be started..."
	oc new-app --template=${MAIN_TEMPLATE}
	sleep 10
} 


function check_deployed_pod {
	echo "Checking final pod"
	dc_name=`oc get dc | tail -1 | awk '{print $1}'`
	dc_template_name=`oc get dc $dc_name --template '{{.spec.template.metadata.labels.name}}'`
	dc_pod=`oc get pods -l name=$dc_template_name | tail -1 | awk '{print $1}'`
	exitfor=1
	count=0
	attempts=100
	while [ $exitfor -ne 0 -a $count -lt $attempts ]; do		
		dc_pod_status=`oc get pod $dc_pod --template '{{.status.phase}}'`
		dc_pod_status_condition=`oc get pod $dc_pod --template '{{range $key, $value := .status.conditions}}{{$value.status}}{{end}}'`
	    if [ $dc_pod_status == "Running" ];then
	    	echo "Pods is running..."
	    	if [ $dc_pod_status_condition == "True" ]; then
				echo "Container is up..."
				exitfor=0
			else
				sleep 5
			fi
	    else 
	    	count=$(($count+1))
	    	echo "Attempt $count/$attempts"
	    	sleep 5
	    fi
	done

	if [ $exitfor -ne 0 ]; then
	    echo "Fail: Pods/container is not up in reasonable time"
	    kill -s TERM $TOP_PID
	fi

	sleep 120

	# Sanity Check
	echo "Sanity check of deployment's URL "
	route=`oc get routes | tail -1 | awk '{print $2}'`
	response_code=`curl -I -L https://$route/index.html --insecure 2>/dev/null | head -n 1 | cut -d$' ' -f2`
	if [ $response_code -eq 200 ]; then
		echo "$route is OK"
	else
		echo "$route response code is $response_code"
		kill -s TERM $TOP_PID
	fi
}

function dev {
	oc login -u$DEV_USER_NAME -p$DEV_USER_PASSWD --server=$OSE_SERVER --insecure-skip-tls-verify=true

	oc project $DEVEL_PROJ_NAME

	#Is this a new deployment or an existing app? Decide based on whether the project is empty or not
	#If BuildConfig exists, assume that the app is already deployed and we need a rebuild

	# Clean up previous auxiliary deployment
	delete_aux_deployment
	create_aux_deployment
	sleep 100

	BUILD_CONFIG=`oc get bc | tail -1 | awk '{print $1}'`

	if [ -z "$BUILD_CONFIG" ]; then
	
		# no app found so create a new one
		create_main_app
	
	    #oc new-app --template=eap6-basic-sti -p \
	  	#APPLICATION_NAME=$APP_NAME,APPLICATION_HOSTNAME=$APP_HOSTNAME,EAP_RELEASE=6.4,GIT_URI=$APP_GIT,GIT_REF=$APP_GIT_REF,GIT_CONTEXT_DIR=$APP_GIT_CONTEXT_DIR\
		#-l name=$APP_NAME
		echo "Find build id"
		BUILD_CONFIG=`oc get bc | tail -1 | awk '{print $1}'`
		exitfor=1
		attempts=75
		count=0
		while [ $exitfor -ne 0 -a $count -lt $attempts ]; do
			BUILD_ID=`oc get builds | tail -1 | awk '{print $1}'`
			if [ -z $BUILD_ID ]; then
	 		   count=$(($count+1))
			   echo "Attempt $count/$attempts"
	           sleep 5
	        else 
	           exitfor=0
	           echo "Build Id is :" ${BUILD_ID}
	        fi 
	     done

	  if [ $exitfor -ne 0 ]; then
	    echo "Fail: Build could not be found after maximum attempts"
	    kill -s TERM $TOP_PID
	  fi 
	else

	  # Application already exists, just need to start a new build
	  echo "App Exists. Triggering application build and deployment"
	  BUILD_ID=`oc start-build ${BUILD_CONFIG}`
  
	fi

	echo "Waiting for build to start"
	exitfor=1
	attempts=25
	count=0
	while [ $exitfor -ne 0 -a $count -lt $attempts ]; do
	  status=`oc get build ${BUILD_ID} --template '{{.status.phase}}'`
	  if [[ $status == "Failed" || $status == "Error" || $status == "Canceled" ]]; then
	    echo "Fail: Build completed with unsuccessful status: ${status}"
	    kill -s TERM $TOP_PID
	  fi
	  if [ $status == "Complete" ]; then
	    echo "Build completed successfully, will test deployment next"
	    exitfor=0
	  fi
  
	  if [ $status == "Running" ]; then
	    echo "Build started"
	    exitfor=0
	  fi
  
	  if [ $status == "Pending" ]; then
	    count=$(($count+1))
	    echo "Attempt $count/$attempts"
	    sleep 5
	  fi
	done

	echo "Checking build result status"
	exitfor=1
	count=0
	attempts=100
	while [ $exitfor -ne 0 -a $count -lt $attempts ]; do
	  status=`oc get build ${BUILD_ID} --template '{{.status.phase}}'`
	  if [[ $status == "Failed" || $status == "Error" || $status == "Canceled" ]]; then
	    echo "Fail: Build completed with unsuccessful status: ${status}"
	    kill -s TERM $TOP_PID
	  fi
	  if [ $status == "Complete" ]; then
	    echo "Build completed successfully, will test deployment next"
	    exitfor=0
	  else 
	    count=$(($count+1))
	    echo "Attempt $count/$attempts"
	    sleep 5
	  fi
	done

	# stream the logs for the build that just started
	oc logs build/$BUILD_ID

	if [ $exitfor -ne 0 ]; then
	    echo "Fail: Build did not complete in a reasonable period of time"
	    kill -s TERM $TOP_PID
	fi

	#sleep 120;

	#check_deployed_pod
	# scale up the test deployment
	#RC_ID=`oc get rc | tail -1 | awk '{print $1}'`

	#echo "Scaling up new deployment $test_rc_id"
	#oc scale --replicas=1 rc $RC_ID


	#echo "Sanity checking for successful test deployment at $HOSTNAME"
	#set +e
	#exitfor=1
	#count=0
	#attempts=100
	#while [ $exitfor -ne 0 -a $count -lt $attempts ]; do
	#  if curl -s --connect-timeout 2 $APP_HOSTNAME >& /dev/null; then
	#    exitfor=0
	#    break
	#  fi
	#  count=$(($count+1))
	#  echo "Attempt $count/$attempts"
	#  sleep 5
	#done
	#set -e

	#if [ $exitfor -ne 0 ]; then
	#    echo "Failed to access test deployment, aborting roll out."
	#    kill -s TERM $TOP_PID
	#fi

	################################################################################
	##Include development test scripts here and fail with kill -s TERM $TOP_PID if the tests fail##
	################################################################################
}


function qa {
	
	oc login -u$DEV_USER_NAME -p$DEV_USER_PASSWD --server=$OSE_SERVER --insecure-skip-tls-verify=true
	oc project $DEVEL_PROJ_NAME	
	
    #is_output=`oc get bc storm-sample-build --template '{{.spec.output.to.name}}'`
    #echo $is_output    
    #IS_NAME="${is_output%:*}"
    #echo $IS_NAME
    
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $1}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $2}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $3}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $4}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $5}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $6}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $7}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $8}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $9}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $10}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $11}'
    #oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $12}'
    
	#is_output=`oc get bc storm-sample-build --template '{{.spec.output.to.name}}'`
	#echo $is_output
	#IS_NAME="${is_output%:*}"
	#echo $IS_NAME
	
    is_output=`oc get bc storm-sample-build --template '{{.spec.output.to.name}}'`
	echo $is_output
	IS_NAME="${is_output%:*}"
	echo $IS_NAME
	BEGINNING=`oc get is ${IS_NAME} | tail -1 | awk '{print $2}'`
	echo $BEGINNING
	#BEGINNING="${BEGINNING_WITH_SHA%@*}"
	#echo $BEGINNING
	IMAGE_SHA=`oc describe imagestreamtags $is_output | head -n 1 | awk '{print $2}'`
	echo $IMAGE_SHA
	FULL_IMAGE_NAME="$BEGINNING@$IMAGE_SHA"
	echo $FULL_IMAGE_NAME
    
    #FULL_IMAGE_NAME=`oc describe is ${IS_NAME} | grep -a1 "Tag" | tail -1 | awk '{print $6}'`
    
    oc login -u$QA_USER_NAME -p$QA_USER_PASSWD --server=$OSE_SERVER --insecure-skip-tls-verify=true
	oc project $QA_PROJ_NAME
	
	# Clean up previous auxiliary deployment
	delete_aux_deployment
	create_aux_deployment
	sleep 200
    #oc delete dc --all
	
	#Find the DeploymentConfig to see if this is a new deployment or just needs an update
	DC_ID=`oc get dc | tail -1| awk '{print $1}'`
	if [ -z $DC_ID ]; then
		create_main_app
		#oc new-app $DEVEL_PROJ_NAME/${IS_NAME}:promote --name=$APP_NAME
		#SVC_ID=`oc get svc | tail -1 | awk '{print $1}'`
		#oc expose service $SVC_ID --hostname=$APP_HOSTNAME
	fi
	
    #Tag to promote to QA
	oc tag $FULL_IMAGE_NAME $QA_PROJ_NAME/${IS_NAME}:qa --insecure=true
    
	sleep 120;
	
	check_deployed_pod
		
}

# Uncomment Project you're working with
dev
#qa
