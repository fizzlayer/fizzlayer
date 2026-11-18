// Supabase sends email links to the home page when their redirect is not allowed. Finish them on the sign-in page.
if (/(^|&)(access_token|error_code)=/.test(location.hash.slice(1))) location.replace('/app/sign-in' + location.hash);
