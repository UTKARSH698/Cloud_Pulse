import {
  CognitoUserPool,
  CognitoUser,
  AuthenticationDetails,
} from "amazon-cognito-identity-js";
import { CONFIG } from "./config";

const userPool = new CognitoUserPool({
  UserPoolId: CONFIG.cognito.userPoolId,
  ClientId: CONFIG.cognito.clientId,
});

export function login(username, password) {
  return new Promise((resolve, reject) => {
    const authDetails = new AuthenticationDetails({
      Username: username,
      Password: password,
    });
    const cognitoUser = new CognitoUser({
      Username: username,
      Pool: userPool,
    });

    cognitoUser.authenticateUser(authDetails, {
      onSuccess: (result) => {
        const idToken = result.getIdToken().getJwtToken();
        resolve(idToken);
      },
      onFailure: (err) => reject(err),
    });
  });
}

export function logout() {
  const user = userPool.getCurrentUser();
  if (user) user.signOut();
}

export function getStoredToken() {
  return sessionStorage.getItem("cp_token");
}

export function storeToken(token) {
  sessionStorage.setItem("cp_token", token);
}

export function clearToken() {
  sessionStorage.removeItem("cp_token");
}
