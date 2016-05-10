# Description:
#   Slack Thread Integration
#
# Commands:
#   thread <text> - Create Slack thread
#   exit <title> <[tag,..]> - Archive thread

module.exports = (robot) ->
  moment = require 'moment-timezone'
  Promise = require 'bluebird'
  Slack = require 'slack-node'
  slack = new Slack process.env.SLACK_API_TOKEN
  Qiita = require "qiita"
  qiita = new Qiita team: process.env.QIITA_TEAM_ID, token: process.env.QIITA_TEAM_TOKEN

  # ユーザー名の辞書（ID:NAME）
  users_dict = {}

  robot.hear /^thread (.*)/i, (msg) ->
    channel = "#{msg.match[1]}"
    current = msg.message.room

    getChannelFromName current, (err, currentId) ->
      if err
        return msg.send err

      getUsersInChannel currentId, (err, users) ->
        if err
          return msg.send err

        newChannelName = "#{current}_#{channel}"
        slack.api "channels.create", name: newChannelName, (err, response) ->
          if err
            return msg.send err

          newId = response.channel.id
          postMessage newId, "created from " + currentId,
          postLink newId, currentId
          inviteUsers users, newId

          msg.send "Created!"

  getUsersInChannel = (id, callback) ->
    slack.api "channels.info", channel: id, (err, response) ->
      if err
        return callback(err)

      callback null, response.channel.members

  getChannelFromName = (channelName, callback) ->
    slack.api "channels.list", {exclude_archived: 1}, (err, response) ->
      if err
        return err

      for val, i in response.channels
        if val.name == channelName
          return callback null, val.id

      return callback err

  postMessage = (to, message) ->
    slack.api "chat.postMessage", channel: to, text: message, (err, response) ->
      if err
        msg.send err

  postLink = (channelId, currentId) ->
    slack.api "chat.postMessage", channel: currentId, text: "<##{channelId}>", (err, response) ->
      if err
        msg.send err

  inviteUsers = (users, channelId) ->
    for val, i in users
      slack.api "channels.invite", channel: channelId, user: val, (err, response) ->
        if err
          msg.send err

  robot.hear /^exit (.*)/i, (msg) ->
    param = "#{msg.match[1]}"
    temp = param.split /\ /
    title = temp[0]
    tags = temp[1] ? ""

    channel = msg.message.room

    getChannelFromName channel, (err, channelId) ->
      getMessages channelId

    messages = ""
    from = null
    getMessages = (channelId, latest) ->
      param = {channel: channelId}
      if latest
        param.latest = latest

      slack.api "channels.history", param, (err, response) ->
        i = 0
        promiseLoop(->
          new Promise((resolve, reject) ->
            i = 0
            resolve()
          )
        , ->
          new Promise((resolve, reject) ->
            resolve i < response.messages.length
          )
        , ->
          new Promise((resolve, reject) ->
            val = response.messages[i]
            console.log i + ": " + moment(Math.round(val.ts)).add(9, 'hours').tz("Asia/Tokyo").format("MM/DD HH:mm") + ": " + val.user + ": " + val.text
            unless from
              match = /^created from (.*)/.exec(val.text)
              if match
                from = match[1]

            findUserName val, (name) ->
              match = /.*has joined the channel.*/.exec(val.text)
              unless match
                messages = "| " + moment(Math.round(val.ts)).add(9, 'hours').tz("Asia/Tokyo").format("MM/DD HH:mm") + " | " + name + " | " + val.text.replace(/\r?\n/g, "<br />").replace(/\&lt;/g,"<").replace(/\&gt;/g,">").replace(/\&amp;/g,"&") + "|\n" + messages
                resolve()
              else
                resolve()

          )
        , ->
          new Promise((resolve, reject) ->
            i++
            resolve()
          )
        ).then ->
          console.log "DONE!"
          if response.has_more
            latest = response.messages[response.messages.length - 1].ts
            getMessages channelId, latest
          else
            messages = "| 時刻 | 発言者 | メッセージ |\n|:--:|:--:|:--|\n" + messages
            postToQiita messages, title, tags, (err, url) ->
              if err
                return msg.send err

              postMessage from, "#{title}のまとめが作成されました\n" + url
              removeChannel channelId, channel, (err, response) ->
                if err
                  return msg.send err

  promiseLoop = (init, condition, callback, increment) ->
    new Promise((resolve, reject) ->
      init().then (_loop = ->
        condition().then ((result) ->
          if result
            callback().then(increment).then _loop, reject
          else
            resolve()
        ), reject
      ), reject
    )

  findUserName = (val, callback) ->
    if val.type and val.type is "message"
      unless val.user
        callback 'slack'
      else
        unless users_dict[val.user]
          slack.api "users.info", {user: val.user}, (err, response) ->
            if err
              callback 'unknown'
            else
              users_dict[val.user] = response.user.name
              callback users_dict[val.user]
        else
          callback users_dict[val.user]

  postToQiita = (messages, title, tags, callback) ->
    qiita.items.post title: title, body: messages, tags: constructTags(tags), coediting: true
    , (err, res, body) ->
      if err
        return callbck err

      callback null, body.url

  removeChannel = (id, name, callback) ->
    slack.api "channels.rename", channel: id, name: name + getNow(), (err, response) ->
      if err
        return callback err

      slack.api "channels.archive", channel: id, (err, response) ->
        if err
          return callback err

        callback null, "OK"

  constructTags = (tags) ->
    if !tags
      return []

    array = tags.split /,/
    params = []

    for val, i in array
      params[i] = {name: val}

    return params

  getNow = () ->
    date = new Date
    y = date.getFullYear()
    m = date.getMonth() + 1
    d = date.getDate()
    h = date.getHours()
    M = date.getMinutes()
    s = date.getSeconds()

    return "#{y}#{m}#{d}#{h}#{M}#{s}"
