Firebase = require("firebase")
Stream = require('stream')
child_process = require("child_process")
optimist = require('optimist')
fs = require('fs')
extend = require('util')._extend
octonode = require("octonode")

process.title = 'Hawkins Worker'

{argv} = optimist.usage('Usage: hawkins-worker --firebase URL')
.options('base', {describe: "Hawkins UI base URL"})
.options('firebase', {describe: "Firebase URL"})
.options('github', {describe: "Github access token"})
.options('help', {alias: "h", describe: "Show this message"})
.options('version', {alias: 'v', describe: "Show version"})

if argv.help
  optimist.showHelp()
  process.exit 0

unless argv.firebase?
  console.log("Missing --firebase")
  process.exit 1

unless argv.base?
  argv.base = argv.firebase.replace("firebaseio.com", "firebaseapp.com")

github = null;
if argv.github?
  github = octonode.client(argv.github)

root = new Firebase(argv.firebase)
pushes = root.child("pushes")
builds = root.child("builds")
logs = root.child("logs")
examples = root.child("examples")

class Worker
  constructor: (queueRef, @callback) ->
    @busy = false
    queueRef.limitToFirst(1).on "child_added", (snap) =>
      @currentItem = snap.ref()
      @pop()

  pop: ->
    if not @busy and @currentItem
      @busy = true
      dataToProcess = null
      toProcess = @currentItem
      @currentItem = null
      toProcess.transaction ((job) ->
        dataToProcess = job
        if job
          null
        else
          return
      ), (error, committed) =>
        throw error if error
        if committed
          @callback dataToProcess, =>
            @busy = false
            @pop()
        else
          @busy = false
          @pop()

new Worker pushes, (push, processNext) ->
  build =
    status: "running",
    startedAt: Date.now()
    push: push
    worker: {pid: process.pid}

  buildRef = builds.ref().push(build)
  buildKey = buildRef.key()
  log = logs.child(buildKey)

  updateGithubStatus = (status) ->
    if github?
      github.repo(push.repository.full_name).status build.push.head_commit.id,
        state: status,
        target_url: "#{argv.base}/builds/#{buildKey}",
        context: "ci/hawkins"
      , ->
        console.log("Updated github status")

  updateGithubStatus("pending")

  output = new Stream.Writable()
  output.write = (data) ->
    process.stdout.write(data)
    log.ref().push(data.toString())

  env = extend({}, process.env)
  extend(env,
    HAWKINS_BUILD: buildKey
    HAWKINS_BRANCH: build.push.ref.replace(/^refs\/heads\//, "")
    HAWKINS_REVISION: build.push.head_commit.id
    HAWKINS_REPOSITORY_URL: build.push.repository.ssh_url
    HAWKINS_REPOSITORY_NAME: build.push.repository.name
    HAWKINS_FIREBASE: argv.firebase
  )

  runner = child_process.spawn "scripts/runner", [], env: env
  buildRef.child("worker").child("runner_pid").ref().set(runner.pid)
  runner.stdout.pipe(output)
  runner.stderr.pipe(output) # TODO: optional?

  runner.on "exit", (exitCode) ->
    buildRef.once "value", (snap) ->
      if snap.val()?
        buildRef.child("finishedAt").ref().set(Date.now())
        if exitCode == 0
          buildRef.child("status").ref().set("success")
          updateGithubStatus("success")
        else
          buildRef.child("status").ref().set("failed")
          updateGithubStatus("failure")

    processNext()

builds.on 'child_removed', (snap) ->
  build = snap.val()

  if build.worker && build.worker.pid == process.pid
    console.log("killing build with pid", build.worker.runner_pid)
    if build.worker.runner_pid?
      try
        process.kill(build.worker.runner_pid, 'SIGINT')
      catch
        # ignore

  logs.child(snap.key()).ref().remove()
  examples.child(snap.key()).ref().remove()
