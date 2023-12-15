#!/usr/bin/env bash

set -euo pipefail

die() { echo "$*"; exit 1; }

WORKSPACE="${WORKSPACE:-$(pwd)}"
TEST_RESOURCES_DIR="${WORKSPACE}/test-resources"
EFFECTIVE_DIR="${WORKSPACE}/effective-bundles"
VALIDATIONS_DIR="${WORKSPACE}/validation-bundles"
DELETE_UNKNOWN_BUNDLES="${DELETE_UNKNOWN_BUNDLES:-"true"}"
CONNECT_MAX_WAIT="${CONNECT_MAX_WAIT:-90}" # 4 mins to connect to the jenkins server
TOKEN_SCRIPT="\
import hudson.model.User
import jenkins.security.ApiTokenProperty
def jenkinsTokenName = 'token-for-test'
def user = User.get('admin', false)
def apiTokenProperty = user.getProperty(ApiTokenProperty.class)
apiTokenProperty.tokenStore.getTokenListSortedByName().findAll {it.name==jenkinsTokenName}.each {
    apiTokenProperty.tokenStore.revokeToken(it.getUuid())
}
def result = apiTokenProperty.tokenStore.generateNewToken(jenkinsTokenName).plainValue
user.save()
new File('/var/jenkins_home/secrets/initialAdminToken').text = result
"

## Takes 1 arg (validation) - starts a server with that particular validation bundle
startServer()
{
    local validationBundle=$1
    echo "${TOKEN_SCRIPT}" > /usr/share/jenkins/ref/init.groovy.d/init_02_admin_token.groovy
    export JAVA_OPTS="-Dcore.casc.config.bundle=${VALIDATIONS_DIR}/${validationBundle}"
    echo "Cleaning plugins directory..."
    rm -rf /var/jenkins_home/plugins /var/jenkins_home/envelope-extension-plugins
    echo "Starting server with bundle '$validationBundle'"
    nohup /usr/local/bin/launch.sh &> /tmp/jenkins-process.log &
    SERVER_PID=$!
    echo "Started server with pid $SERVER_PID"
    echo "$SERVER_PID" > "/tmp/jenkins-pid.${SERVER_PID}"
    local serverStarted=''
    ENDTIME=$(( $(date +%s) + CONNECT_MAX_WAIT )) # Calculate end time.
    while [ "$(date +%s)" -lt $ENDTIME ]; do
        echo "$(date): $(date +%s) -lt $ENDTIME"
        if [[ "200" == $(curl -o /dev/null -sw "%{http_code}" "http://localhost:8080/whoAmI/api/json") ]]; then
            serverStarted='y'
            sleep 5 # just a little respite
            echo "Server started" && break
        else
            sleep 5
            echo "Waiting for server to start"
        fi
    done
    if [ -z "$serverStarted" ]; then
        echo "$(date): $(date +%s) -lt $ENDTIME"
        echo "ERROR: Server not started in time. Printing the jenkins log...."
        cat /tmp/jenkins-process.log
        stopServer
        exit 1
    fi
}

## Takes 1 arg (bundleZipLocation) - validates bundle and places result in the "${bundleZipLocation}.json"
runCurlValidation()
{
    local zipLocation="$1"
    local jsonLocation="${zipLocation//zip/json}"
    local summaryLocation="${zipLocation//zip/txt}" # placeholder to put the summary afterwards
    local curlExitCode=''
    touch "$summaryLocation"
    echo "Running validation with '$zipLocation', writing to '$jsonLocation"
    set +e
    echo "token $(cat /var/jenkins_home/secrets/initialAdminToken)"
    curl -s -X POST -u "admin:$(cat /var/jenkins_home/secrets/initialAdminToken)" \
        "http://localhost:8080/casc-bundle-mgnt/casc-bundle-validate" \
        --header "Content-type: application/zip" \
        --data-binary "@${zipLocation}" \
        > "${jsonLocation}"
    curlExitCode=$?
    set -e
    if [ "${curlExitCode}" -eq 0 ]; then
        echo "Curl command successful. Printing resulting json '${jsonLocation}'."
        cat "${jsonLocation}"
    else
        echo "Curl command failed with exit code ${curlExitCode}. See logs above."
        exit 1
    fi
}

## Takes 0 args - uses SERVER_PID file from startServer to stop the server
stopServer()
{
    echo "Stopping server/s if necessary..."
    for pidFile in /tmp/jenkins-pid*; do
        [ -f "$pidFile" ] || break # nothing found
        local pid=''
        pid=$(cat "${pidFile}")
        echo "Stopping server with pid '$pid'"
        kill "$pid" || true
    done
    rm -f "/tmp/jenkins-pid."*
}

## Takes 1 optional args (bundles) - if set run only those, otherwise run all validations (assumes the 'test-resources' directory has been created by the 'cascgen testResources')
runValidationsChangedOnly()
{
    local bundles=''
    getChangedSources
    if [ -f "${TEST_RESOURCES_DIR}/.changed-effective-bundles" ]; then
        bundles=$(cat "${TEST_RESOURCES_DIR}/.changed-effective-bundles")
    fi
    if [ -n "$bundles" ]; then
        echo "Changed effective bundles detected '$bundles'. Running validations..."
        runValidations "$bundles"
    else
        echo "No changed effective bundles detected. Not doing anything..."
    fi
}

## Takes 1 optional args (bundles) - if set run only those, otherwise run all validations (assumes the 'test-resources' directory has been created by the 'cascgen testResources')
runValidations()
{
    local bundles="${1:-}"
    for validationBundleTestResource in "${TEST_RESOURCES_DIR}/"*; do
        local validationBundle='' bundlesFound=''
        validationBundle=$(basename "$validationBundleTestResource")
        for b in $bundles; do
            local bZip="${validationBundleTestResource}/${b}.zip"
            [ ! -f "${bZip}" ] || bundlesFound="${bundlesFound} ${bZip}"
        done
        if [ -z "${bundles}" ] || [ -n "$bundlesFound" ]; then
            echo "Analysing validation bundle '${validationBundle}'..."
            startServer "$validationBundle"
            if [ -n "$bundlesFound" ]; then
                for bundleZipPath in $bundlesFound; do
                    runCurlValidation "${bundleZipPath}"
                done
            else
                for bundleZipPath in "${validationBundleTestResource}/"*.zip; do
                    runCurlValidation "${bundleZipPath}"
                done
            fi
            stopServer
            sleep 2
        else
            echo "Skipping validation bundle '${validationBundle}' since no matching bundles found."
        fi
    done
}

## Adds metadata above test-resources
## Assumes the 'test-resources' directory has been created by the 'cascgen testResources'
## - .changed-files: all the from the PR
## - .changed-effective-bundles: space spearated list of changed bundles from the PR
getChangedSources()
{
    if [ -n "${CHANGE_TARGET:-}" ] && [ -n "${BRANCH_NAME:-}" ]; then
        local targetSha='' changeSha='' headSha=''
        targetSha=$(git rev-parse "origin/${CHANGE_TARGET}")
        changeSha=$(git rev-parse "origin/${BRANCH_NAME}")
        headSha=$(git rev-parse HEAD)
        echo "CHANGED RESOURCES - Looking for changes between branch and base..."
        if ! git diff --exit-code --name-only "${targetSha}..${changeSha}"; then
            echo "CHANGED RESOURCES - Found the changed resources above."
            git diff --name-only "${targetSha}..${changeSha}" > "${TEST_RESOURCES_DIR}/.changed-files"
        fi
        grep -oE "effective-bundles/.*/" "${TEST_RESOURCES_DIR}/.changed-files" \
            | cut -d/ -f2 | sort -u | xargs > "${TEST_RESOURCES_DIR}/.changed-effective-bundles"
        echo "CHANGED RESOURCES - Found the following changed bundles:"
        cat "${TEST_RESOURCES_DIR}/.changed-effective-bundles"
        echo "CHANGED RESOURCES - Checking to ensure branch is up to date..."
        if [[ "$headSha" != "$changeSha" ]]; then
            die "PR requires merge commit. Please rebase or otherwise update your branch. Not accepting."
        fi
    else
        die "We need CHANGE_TARGET and BRANCH_NAME."
    fi
}

## Prints a summary (assumes createTestResources has been run, and that some validation results in the form of <bundeName>.json next to <bundeName>.zip)
getTestResultReport()
{
    local bundleDir=''
    local bundleName=''
    local bundleStatus=''
    local bundleJson=''
    local bundleTxt='' # marker file to say we expect a resulting json
    local problemFound=''
    local msg="Analysis Summary:"
    echo "$msg: starting analysis. If you see this, there was a problem during the analysis." > "${TEST_RESOURCES_DIR}/test-summary.txt"
    echo "Analysing bundles..."
    while IFS= read -r -d '' bundleDir; do
        bundleName=$(basename "$bundleDir")
        echo "Looking at bundle: ${bundleName}"
        bundleTxt=$(find "${TEST_RESOURCES_DIR}" -type f -name "${bundleName}.txt")
        if [ -f "${bundleTxt}" ]; then
            # result json expected at least
            bundleJson=$(find "${TEST_RESOURCES_DIR}" -type f -name "${bundleName}.json")
            if [ -f "${bundleJson}" ]; then
                jq . "${bundleJson}"
                if [[ "true" == $(jq '.valid' "${bundleJson}") ]]; then
                    bundleStatus='OK  - VALID WITHOUT WARNINGS'
                    if jq -r '."validation-messages"[]' "${bundleJson}" | grep -qvE "^INFO"; then
                        bundleStatus='NOK - CONTAINS NON-INFO MESSAGES'
                    fi
                else
                    bundleStatus='NOK - INVALID'
                fi
            else
                bundleStatus='NOK - VALIDATION JSON EXPECTED BUT MISSING'
            fi
        else
            bundleStatus='N/A  - NOT TESTED IN THIS PR'
        fi
        if [[ "${bundleStatus}" =~ NOK ]]; then
            problemFound='y'
        fi
        msg=$(printf "%s\n%s: %s\n" "$msg" "$bundleName" "$bundleStatus")
        echo "$msg"
    done < <(find "${EFFECTIVE_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo
    echo "$msg"
    echo "$msg" > "${TEST_RESOURCES_DIR}/test-summary.txt"
    [ -z "$problemFound" ] || die "Problems found. Dying, alas 'twas so nice..."
}

## Uses kubectl and kustomize to add two labels (CI_VERSION and CURRENT_GIT_SHA) and  apply the bundle config maps. Assumes env vars NAMESPACE and DELETE_UNKNOWN_BUNDLES (Removes any bundles which are no longer in the list for this release)
applyBundleConfigMaps()
{
    local headSha='' configMaps=''
    headSha=$(git rev-parse HEAD)
    echo "Adding current git sha and CI_VERSION to the kustomize configuration..."
    [ -n "$headSha" ] || die "The current git sha is empty."
    [ -n "$CI_VERSION" ] || die "The env CI_VERSION is empty."
    cd "${EFFECTIVE_DIR}"
    kustomize edit set label "bundle-mgr/version:$CI_VERSION" "bundle-mgr/sha:$headSha"
    echo "Applying the kustomize configuration..."
    kubectl kustomize | kubectl -n "$NAMESPACE" apply -f -
    configMaps=$(kubectl -n "$NAMESPACE" get cm -l "bundle-mgr/version=$CI_VERSION" -o jsonpath="{.items[*].metadata.name}")
    for cm in $configMaps; do
        local bundleFound=''
        bundleFound=$(cm=$cm yq '.configMapGenerator[]|select(.name == strenv(cm)).name' kustomization.yaml)
        if [ -n "${bundleFound}" ]; then
            echo "ConfigMap '$cm' in current list."
        else
            echo "ConfigMap '$cm' NOT in current list."
            if [ "true" == "${DELETE_UNKNOWN_BUNDLES}" ]; then
                echo "ConfigMap '$cm' will be deleted."
                kubectl -n "$NAMESPACE" delete cm "$cm"
            else
                echo "ConfigMap '$cm' unknown but will be ignored (set DELETE_UNKNOWN_BUNDLES to true to delete)."
            fi
        fi
    done
    cd - &>/dev/null
}

## Print help; use "help NAME" to show details
help()
{
    (( $# > 0 )) && {
        type "$@"
        return $?
    }

    local DESC=''

    while read -r; do
        case $REPLY in
            *\(\))
                [ "$DESC" ] || continue
                echo "${REPLY%(*} - $DESC"
                DESC=
                ;;
            \#\#\ *)
                [ "$DESC" ] && continue
                DESC=${REPLY##*#}
                ;;
        esac
    done < "$0"
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    "${@:-help}"
fi