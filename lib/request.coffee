_          = require("lodash")
r          = require("request")
rp         = require("request-promise")
url        = require("url")
tough      = require("tough-cookie")
moment     = require("moment")
Promise    = require("bluebird")
extension  = require("@cypress/core-extension")
automation = require("./automation")
statusCode = require("./util/status_code")

Cookie = tough.Cookie
CookieJar = tough.CookieJar

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

newCookieJar = ->
  j = new CookieJar(undefined, {looseMode: true})

  ## match the same api signature as @request
  {
    _jar: j

    toJSON: ->
      j.toJSON()

    setCookie: (cookieOrStr, uri, options) ->
      j.setCookieSync(cookieOrStr, uri, options)

    getCookieString: (uri) ->
      j.getCookieStringSync(uri, {expire: false})

    getCookies: (uri) ->
      j.getCookiesSync(uri, {expire: false})
  }

flattenCookies = (cookies) ->
  _.reduce cookies, (memo, cookie) ->
    memo[cookie.name] = cookie.value
    memo
  , {}

reduceCookieToArray = (c) ->
  _.reduce c, (memo, val, key) ->
    memo.push [key.trim(), val.trim()].join("=")
    memo
  , []

createCookieString = (c) ->
  reduceCookieToArray(c).join("; ")

module.exports = (options = {}) ->
  defaults = {
    timeout: options.timeout ? 20000
    # forever: true
  }

  r  = r.defaults(defaults)
  rp = rp.defaults(defaults)

  return {
    r: require("request")

    rp: require("request-promise")

    reduceCookieToArray: reduceCookieToArray

    createCookieString: createCookieString

    create: (strOrOpts, promise) ->
      switch
        when _.isString(strOrOpts)
          opts = {
            url: strOrOpts
          }
        else
          opts = strOrOpts

      opts.url = url.parse(opts.url)

      ## parse port into a legit number
      ## to fix issue with request
      ## https://github.com/cypress-io/cypress/issues/222
      if p = opts.url.port
        opts.url.port = _.toNumber(p)

      if promise
        rp(opts)
      else
        r(opts)

    contentTypeIsJson: (response) ->
      ## TODO: use https://github.com/jshttp/type-is for this
      response?.headers?["content-type"]?.includes("application/json")

    parseJsonBody: (body) ->
      try
        JSON.parse(body)
      catch e
        body

    normalizeResponse: (response) ->
      response = _.pick(response, "statusCode", "body", "headers")

      ## normalize status
      response.status = response.statusCode
      delete response.statusCode

      ## normalize what is an ok status code
      response.isOkStatusCode = statusCode.isOk(response.status)

      response.statusText = statusCode.getText(response.status)

      ## if body is a string and content type is json
      ## try to convert the body to JSON
      if _.isString(response.body) and @contentTypeIsJson(response)
        response.body = @parseJsonBody(response.body)

      return response

    setJarCookies: (jar, automationFn) ->
      setCookie = (cookie) ->
        cookie.name = cookie.key

        ## TODO: fix this
        return if cookie.name and cookie.name.startsWith("__cypress")

        ## tough-cookie will return us a cookie that looks like this....
        # { key: 'secret-session',
        #   value: 's%3AxMYoMAXnnMN2pzjYKJx21Id9zjQOaPsT.aKJv1mlfNlCEtrPUjgt48KX0c7xNiB%2Bb0fLijmi48dY',
        #   domain: 'session.foobar.com',
        #   path: '/',
        #   httpOnly: true,
        #   extensions: [ 'SameSite=Strict' ],
        #   hostOnly: true,
        #   creation: '2016-09-04T18:48:06.882Z',
        #   lastAccessed: '2016-09-04T18:48:06.882Z',
        #   name: 'secret-session' }
        #
        # { key: '2293-session',
        #   value: 'true',
        #   domain: 'localhost',
        #   path: '/',
        #   hostOnly: true,
        #   creation: '2016-09-05T03:03:20.780Z',
        #   lastAccessed: '2016-09-05T03:03:20.780Z',
        #   name: '2293-session' }

        ## lets construct the url ourselves right now
        cookie.url = extension.getCookieUrl(cookie)

        ## https://github.com/SalesforceEng/tough-cookie#setcookiecookieorstring-currenturl-options-cberrcookie
        ## a host only cookie is when domain was not explictly
        ## set in the Set-Cookie header and instead was implied.
        ## when this is the case we need to remove the domain
        ## property else our cookie will incorrectly be set
        ## as a domain cookie
        if ho = cookie.hostOnly
          cookie = _.omit(cookie, "domain")

        switch
          when cookie.maxAge?
            ## when we have maxAge
            ## prefer that
            ## unix returns us time in seconds
            ## from the epoc + we add that
            ## to maxAge since thats relative seconds
            ## from now
            cookie.expiry = moment().unix() + cookie.maxAge
          when ex = cookie.expires
            ## tough cookie provides javascript date
            ## formatted expires
            cookie.expiry = moment(ex).unix()

        automationFn("set:cookie", cookie)
        .then ->
          ## the automation may return us null in
          ## the case an expired cookie is removed
          automation.normalizeCookieProps(cookie)

      Promise.try ->
        store = jar.toJSON()

        ## this likely needs
        ## to be an 'each' not a map
        ## since we need to set cookies
        ## in sequence and not all at once
        ## because cookies could have colliding
        ## values which need to be set in order
        Promise.each(store.cookies, setCookie)

    sendStream: (headers, automation, options = {}) ->
      _.defaults options, {
        headers: {}
        jar: true
      }

      if ua = headers["user-agent"]
        options.headers["User-Agent"] = ua

      ## create a new jar instance
      ## unless its falsy or already set
      if options.jar is true
        options.jar = newCookieJar()

      _.extend options, {
        strictSSL: false
      }

      setCookies = (cookies) =>
        return if _.isEmpty(cookies)

        options.headers["Cookie"] = createCookieString(cookies)

      send = =>
        str = @create(options)
        str.getJar = -> options.jar
        str

      automation("get:cookies", {url: options.url})
      .then(flattenCookies)
      .then(setCookies)
      .then(send)

    send: (headers, automation, options = {}) ->
      _.defaults options, {
        headers: {}
        gzip: true
        jar: true
        cookies: true
        followRedirect: true
      }

      if ua = headers["user-agent"]
        options.headers["User-Agent"] = ua

      ## create a new jar instance
      ## unless its falsy or already set
      if options.jar is true
        options.jar = newCookieJar()

      _.extend options, {
        strictSSL: false
        simple: false
        resolveWithFullResponse: true
      }

      ## https://github.com/cypress-io/cypress/issues/322
      ## either turn these both on or off
      options.followAllRedirects = options.followRedirect

      if options.form is true
        ## reset form to whatever body is
        ## and nuke body
        options.form = options.body
        delete options.json
        delete options.body

      setCookies = (cookies) =>
        return if _.isEmpty(cookies)

        options.headers["Cookie"] = createCookieString(cookies)

      send = =>
        ms = Date.now()

        @create(options, true)
        .then(@normalizeResponse.bind(@))
        .then (resp) =>
          resp.duration = Date.now() - ms

          if options.followRedirect is false and (loc = resp.headers.location)
            ## resolve the new location head against
            ## the current url
            redirect = url.resolve(options.url, loc)
            resp.redirectedTo = redirect

          if options.jar
            @setJarCookies(options.jar, automation)
            .return(resp)
          else
            resp

      if c = options.cookies
        ## if we have a cookie object then just
        ## send the request up!
        if _.isObject(c)
          setCookies(c)
          send()
        else
          ## else go get the cookies first
          ## then make the request

          ## TODO: we can simply use the 'url' property on the cookies API
          ## which automatically pulls all of the cookies that would be
          ## set for that url!
          automation("get:cookies", {url: options.url})
          .then(flattenCookies)
          .then(setCookies)
          .then(send)
      else
        send()

  }