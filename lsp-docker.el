;;; lsp-docker.el --- LSP Docker integration         -*- lexical-binding: t; -*-

;; Copyright (C) 2019  Ivan Yonchovski

;; Author: Ivan Yonchovski <yyoncho@gmail.com>
;; URL: https://github.com/emacs-lsp/lsp-docker
;; Keywords: languages langserver
;; Version: 1.0.0
;; Package-Requires: ((emacs "25.1") (dash "2.14.1") (lsp-mode "6.2.1"))


;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run language servers in containers

;;; Code:
(require 'lsp-mode)
(require 'dash)

(defun lsp-docker--uri->path (path-mappings docker-container-name uri)
  "Turn docker URI into host path.
Argument PATH-MAPPINGS dotted pair of (host-path . container-path).
Argument DOCKER-CONTAINER-NAME name to use when running container.
Argument URI the uri to translate."
  (let ((path (lsp--uri-to-path-1 uri)))
    (-if-let ((local . remote) (-first (-lambda ((_ . docker-path))
                                         (s-contains? docker-path path))
                                       path-mappings))
        (s-replace remote local path)
      (format "/docker:%s:%s" docker-container-name path))))

(defun lsp-docker--path->uri (path-mappings path)
  "Turn host PATH into docker uri.
Argument PATH-MAPPINGS dotted pair of (host-path . container-path).
Argument PATH the path to translate."
  (lsp--path-to-uri-1
   (-if-let ((local . remote) (-first (-lambda ((local-path . _))
                                        (s-contains? local-path path))
                                      path-mappings))
       (s-replace local remote path)
     (user-error "The path %s is not under path mappings" path))))


(defvar lsp-docker-container-name-suffix 0
  "Used to prevent collision of container names.")

(defvar lsp-docker-command "docker"
  "The docker command to use.")

(defun lsp-docker-launch-new-container (docker-container-name path-mappings docker-image-id server-command)
  "Return the docker command to be executed on host.
Argument DOCKER-CONTAINER-NAME name to use for container.
Argument PATH-MAPPINGS dotted pair of (host-path . container-path).
Argument DOCKER-IMAGE-ID the docker container to run language servers with.
Argument SERVER-COMMAND the language server command to run inside the container."
  (cl-incf lsp-docker-container-name-suffix)
  (split-string
   (--doto (format "%s run --name %s-%d --rm -i %s %s %s"
		   lsp-docker-command
		   docker-container-name
		   lsp-docker-container-name-suffix
		   (->> path-mappings
			(-map (-lambda ((path . docker-path))
				(format "-v %s:%s" path docker-path)))
			(s-join " "))
		   docker-image-id
		   server-command))
   " "))

(defun lsp-docker-exec-in-container (docker-container-name server-command)
  "Return command to exec into running container.
Argument DOCKER-CONTAINER-NAME name of container to exec into.
Argument SERVER-COMMAND the command to execute inside the running container."
(split-string
   (format "docker exec -i %s %s" docker-container-name server-command)))

(cl-defun lsp-docker-register-client (&key server-id
                                           docker-server-id
                                           path-mappings
                                           docker-image-id
                                           docker-container-name
                                           priority
                                           server-command
                                           launch-server-cmd-fn)
  "Registers docker clients with lsp"
  (if-let ((client (copy-lsp--client (gethash server-id lsp-clients))))
      (progn
        (setf (lsp--client-server-id client) docker-server-id
              (lsp--client-uri->path-fn client) (-partial #'lsp-docker--uri->path
                                                          path-mappings
                                                          docker-container-name)
              (lsp--client-path->uri-fn client) (-partial #'lsp-docker--path->uri path-mappings)
              (lsp--client-new-connection client) (plist-put
                                                   (lsp-stdio-connection
                                                    (lambda ()
                                                      (funcall (or launch-server-cmd-fn #'lsp-docker-launch-new-container)
                                                               docker-container-name
                                                               path-mappings
                                                               docker-image-id
                                                               server-command)))
                                                   :test? (lambda (&rest _)
                                                            (-any?
                                                             (-lambda ((dir))
                                                               (f-ancestor-of? dir (buffer-file-name)))
                                                             path-mappings)))
              (lsp--client-priority client) (or priority (lsp--client-priority client)))
        (lsp-register-client client))
    (user-error "No such client %s" server-id)))

(defvar lsp-docker-default-client-packages
  '(lsp-bash
    lsp-clangd
    lsp-css
    lsp-dockerfile
    lsp-go
    lsp-html
    lsp-javascript
    lsp-pyls)
  "Default list of client packages to load.")

(defvar lsp-docker-default-client-configs
  (list
   (list :server-id 'bash-ls :docker-server-id 'bashls-docker :server-command "bash-language-server start")
   (list :server-id 'clangd :docker-server-id 'clangd-docker :server-command "ccls")
   (list :server-id 'css-ls :docker-server-id 'cssls-docker :server-command "css-languageserver --stdio")
   (list :server-id 'dockerfile-ls :docker-server-id 'dockerfilels-docker :server-command "docker-langserver --stdio")
   (list :server-id 'gopls :docker-server-id 'gopls-docker :server-command "gopls")
   (list :server-id 'html-ls :docker-server-id 'htmls-docker :server-command "html-languageserver --stdio")
   (list :server-id 'pyls :docker-server-id 'pyls-docker :server-command "pyls")
   (list :server-id 'ts-ls :docker-server-id 'tsls-docker :server-command "typescript-language-server --stdio"))
  "Default list of client configurations.")

(cl-defun lsp-docker-init-clients (&key
					path-mappings
					(docker-image-id "emacslsp/lsp-docker-langservers")
					(docker-container-name "lsp-container")
					(priority 10)
					(client-packages lsp-docker-default-client-packages)
					(client-configs lsp-docker-default-client-configs))
  "Loads the required client packages and registers the required clients to run with docker.

:path-mappings is an alist of local paths and their mountpoints
in the docker container.
Example: '((\"/path/to/projects\" . \"/projects\"))

:docker-image-id is the identifier for the docker image to be
used for all clients, as a string.

:docker-container-name is the name to use for the container when
it is started.

:priority is the priority with which to register the docker
clients with lsp.  (See the library ‘lsp-clients’ for details.)

:client-packages is a list of libraries to load before registering the clients.

:client-configs is a list of configurations for the various
clients you wish to use with ‘lsp-docker’.  Each element takes
the form
'(:server-id 'example-ls
  :docker-server-id 'examplels-docker
  :docker-image-id \"examplenamespace/examplels-docker:x.y\"
  :docker-container-name \"examplels-container\"
  :server-command \"run_example_ls.sh\")
where
:server-id is the ID of the language server, as defined in the
library ‘lsp-clients’.

:docker-server-id is any arbitrary unique symbol used internally
by ‘lsp’ to distinguish it from non-docker clients for the same
server.

:docker-image-id is an optional property to override this
function's :docker-image-id argument for just this client.  If
you specify this, you MUST also specify :docker-container-name.

:docker-container-name is an optional property to override this
function's :docker-container-name argument for just this client.
This MUST be specified if :docker-image-id is specified, but is
otherwise optional.

:server-command is a string specifying the command to run inside
the docker container to run the language server."
  (seq-do (lambda (package) (require package nil t)) client-packages)
  (let ((default-docker-image-id docker-image-id))
    (seq-do (-lambda ((&plist :server-id :docker-server-id :docker-image-id :docker-container-name :server-command))
        (when (and docker-image-id (not docker-container-name))
          (user-error "Invalid client definition for server ID %S. You must specify a container name when specifying an image ID."
                 server-id))
        (lsp-docker-register-client
         :server-id server-id
         :priority priority
         :docker-server-id docker-server-id
         :docker-image-id (or docker-image-id default-docker-image-id)
         :docker-container-name (if docker-image-id
                                    docker-container-name
                                  default-docker-container-name)
         :server-command server-command
         :path-mappings path-mappings
         :launch-server-cmd-fn #'lsp-docker-launch-new-container))
      client-configs)))

(provide 'lsp-docker)
;;; lsp-docker.el ends here
