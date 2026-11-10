# Connect your Google accounts

Postvak talks to Gmail and Google Calendar with your own Google Cloud project. It takes about 10 minutes, and costs nothing.

1. Open [console.cloud.google.com](https://console.cloud.google.com) and sign in with any of your accounts. Create a project named `Postvak`.
2. Under **APIs & Services, Library**, enable **Gmail API** and **Google Calendar API**.
3. Under **Google Auth Platform, Branding**, fill in the app name `Postvak` and your address.
4. Under **Audience**, choose **External**. Add each address you will connect as a test user.
5. Under **Data Access**, add these scopes:
   - `https://www.googleapis.com/auth/gmail.modify`
   - `https://www.googleapis.com/auth/gmail.settings.basic`
   - `https://www.googleapis.com/auth/calendar`
   - `userinfo.email`, `userinfo.profile` and `openid`
6. Under **Clients**, create a client of type **Desktop app**. Copy the client ID and client secret before you close the dialog, because Google may not show the secret again.
7. **Important:** in Testing status, Google ends every sign-in after 7 days. To avoid that, first add a public **home page** and **privacy policy** link under **Branding**, because **Publish app** stays disabled without them. Then click **Publish app** under **Audience**. Published without verification, Google shows an "unverified app" warning at sign-in, and you pass it through **Advanced**. That warning is about your own project.
8. In Postvak, open **Settings, Accounts**. Paste the client ID and secret, and click **Add Google Account** once per address. The browser opens for each one.

The first sync of each account fetches 12 months of mail, and can take a while on a large mailbox. You can use the app during it.

If an organisation manages one of your Workspace domains, its admin may have to allow the app. Domains you control yourself need nothing extra.
