# Changelog

What landed on `main` from November 2 through November 13, 2026. Each line is a merged pull request title. The date is the commit timestamp in US Pacific, which is how these commits are recorded. The same list is on the website at [/changelog](https://fizzlayer.com/changelog).

## November 13, 2026

- Fail CI when a tracked file is build output. (#34)
- Add a Gleam Lustre SPA skeleton at /app. (#31)
- Rebrand the homepage around Gateway and move Sensors to /sensors. (#27)
- Return new accounts to sensor selection after the plan step. (#26)

## November 12, 2026

- Retry image publishes when the base-image registry rate-limits. (#25)
- Ask for a plan after the account exists. (#24)

## November 10, 2026

- Choose a plan while creating an account. (#23)
- Add a GitHub link to the public navigation. (#22)
- Generate self-host secrets inside the API image and drop the demo recorder. (#21)
- Run Fizzlayer from a compose file that does not need a checkout. (#20)
- Document Docker self-hosting and license the project under Apache 2.0. (#19)
- Add a Docker Compose self-host stack and image publish workflow. (#18)
- Add pricing, status, and enterprise pages. (#17)
- Document the production live stream paths. (#16)
- Release the CLI as 0.2.0 and install the newest cli-v tag. (#15)
- Add live WebSocket and MQTT streaming on Supabase Compute. (#14)
- Serve the Home Assistant badges from the site. (#13)
- Show the Home Assistant code even when Advanced Mode is on. (#12)
- Install the Home Assistant integration before adding it. (#11)

## November 9, 2026

- Match Home Assistant migrations to production. (#10)
- Add a one-click Home Assistant integration. (#9)

## November 3, 2026

- Pair a phone before calling it, and limit calls to paid plans. (#8)

## November 2, 2026

- Add GitHub sign-in and sign-up. (#7)
- Refresh the social preview card to match the current site. (#6)
- Open sign-up, retire the waitlist, and tighten plan and request limits. (#5)
- Call when a sensor goes silent, and send queued calls on a schedule. (#4)
- Fix demo call preview, greenhouse readings, and Fizz answers. (#3)
