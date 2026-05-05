import jenkins.model.*
import hudson.model.*
import org.jvnet.hudson.plugins.m2release.*
import org.jenkinsci.plugins.managedscripts.*
import hudson.tasks.BuildStepRunner

// === CONFIGURATION ===
def dryRun = true  // << Set to false to apply changes
def excludedFolder = "iam-cloud"
def newGoals = '-Dresume=false -Darguments="-Dadditionalparam=-Xdoclint:none -Dmaven.deploy.skip=true" release:prepare release:perform -P wso2-release'
def managedScriptName = "XYZ"

def isExcluded(Job job) {
    return job.getFullName().startsWith("${excludedFolder}/")
}

// === MAIN LOGIC ===
Jenkins.instance.getAllItems(hudson.model.Project).each { job ->
    if (isExcluded(job)) {
        println "🚫 Skipping excluded job: ${job.fullName}"
        return
    }

    def wrappers = job.getBuildWrappersList()
    def m2Release = wrappers.find { it instanceof M2ReleaseBuildWrapper }

    if (!m2Release) {
        // Skip jobs that don't use Maven Release Build
        return
    }

    println "🔍 Checking job: ${job.fullName}"
    def changed = false

    // === Update Maven Release Build ===
    if (m2Release.getGoalsAndOptions() != newGoals || !m2Release.getUseNexus3()) {
        println "  🛠️ Updating Maven Release Build configuration:"
        println "     - Old goals: ${m2Release.getGoalsAndOptions()}"
        println "     - New goals: ${newGoals}"
        println "     - Enabling Nexus 3 Upload"

        m2Release.setGoalsAndOptions(newGoals)
        m2Release.setUseNexus3(true)
        changed = true
    } else {
        println "  ✅ Maven Release Build config already up to date"
    }

    // === Check/Update Post Step ===
    def postSteps = job.getPostbuilders()
    def existingStep = postSteps.find { it instanceof ManagedScript && it.getScriptName() == managedScriptName }

    if (!existingStep) {
        println "  ➕ Adding Managed Script '${managedScriptName}' as a Post Step (run only if build succeeds)"
        def newScript = new ManagedScript(managedScriptName, [:])
        newScript.setRunCondition(BuildStepRunner.BUILD_SUCCESSFUL)
        if (!dryRun) postSteps.add(newScript)
        changed = true
    } else if (existingStep.getRunCondition() != BuildStepRunner.BUILD_SUCCESSFUL) {
        println "  🔁 Updating existing Managed Script run condition to 'only if build succeeds'"
        if (!dryRun) existingStep.setRunCondition(BuildStepRunner.BUILD_SUCCESSFUL)
        changed = true
    } else {
        println "  ✅ Managed Script '${managedScriptName}' already correctly configured"
    }

    // === Save Changes ===
    if (changed) {
        if (!dryRun) {
            job.save()
            println "  💾 Saved changes for job: ${job.fullName}"
        } else {
            println "  📝 Would save changes for job: ${job.fullName}"
        }
    } else {
        println "  🔸 No changes needed for job: ${job.fullName}"
    }
}
