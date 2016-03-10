#!groovy

stage 'Dev'
node {
    checkout scm
    sh "jenkins/build-dev.sh"
}

stage 'approve'
timeout(time: 7, unit: 'DAYS') {
input message: 'Do you want to deploy?', submitter: 'ops'
}
stage name:'deploy', concurrency: 1
node {
	checkout scm
	sh "jenkins/build-qa.sh"
}