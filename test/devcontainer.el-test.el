(require 'mocker)
(require 'devcontainer-mode)

(defmacro fixture-tmp-dir (test-repo &rest body)
  (declare (indent 1))
  `(let* ((tmp-dir (make-temp-file "devcontainer-test-repo" 'directory))
          (project-root-dir (file-name-as-directory tmp-dir)))
     (shell-command-to-string (format "tar -xf test/%s.tar --directory %s" ,test-repo tmp-dir))
     (mocker-let ((project-current () ((:output (cons 'foo project-root-dir) :min-occur 0)))
                  (project-root (project) ((:input `((foo . ,project-root-dir)) :output project-root-dir :min-occur 0))))
       (unwind-protect
           ,@body
         (delete-directory tmp-dir 'recursively)))))

(ert-deftest devcontainer-command-unavailable ()
  (mocker-let ((executable-find (cmd) ((:input '("devcontainer") :output nil))))
    (should-not (devcontainer-find-executable))))

(ert-deftest devcontainer-command-available ()
  (mocker-let ((executable-find (cmd) ((:input '("devcontainer") :output "/path/to/devcontainer"))))
    (should (equal (devcontainer-find-executable) "/path/to/devcontainer"))))

(ert-deftest container-needed ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (should (devcontainer-container-needed))))

(ert-deftest container-not-needed ()
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (should-not (devcontainer-container-needed))))

(ert-deftest container-id-no-container-defined ()
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (should-not (devcontainer-container-id))))

(ert-deftest container-id-no-container-set-up ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd (format
                "docker container ls --filter label=devcontainer.local_folder=%s --format {{.ID}} --all"
                tmp-dir)))
      (mocker-let ((shell-command-to-string (_cmd) ((:input `(,cmd) :output ""))))
        (should-not (devcontainer-container-id))))))

(ert-deftest container-id-container-set-up ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd (format
                "docker container ls --filter label=devcontainer.local_folder=%s --format {{.ID}} --all"
                tmp-dir)))
      (mocker-let ((shell-command-to-string (_cmd) ((:input `(,cmd) :output "abc\n"))))
        (should (equal (devcontainer-container-id) "abc"))))))

(ert-deftest container-id-no-container-running ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd (format
                "docker container ls --filter label=devcontainer.local_folder=%s --format {{.ID}}"
                tmp-dir)))
      (mocker-let ((shell-command-to-string (_cmd) ((:input `(,cmd) :output ""))))
        (should-not (devcontainer-container-up))))))

(ert-deftest container-id-container-running ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd (format
                "docker container ls --filter label=devcontainer.local_folder=%s --format {{.ID}}"
                tmp-dir)))
      (mocker-let ((shell-command-to-string (_cmd) ((:input `(,cmd) :output "abc\n"))))
        (should (equal (devcontainer-container-up) "abc"))))))

(ert-deftest container-up-no-devcontainer-needed ()
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (mocker-let ((get-buffer-create (name) ((:occur 0)))
                 (message (msg) ((:input '("Project does not use a devcontainer.")))))
      (devcontainer-up))))

(ert-deftest container-up-devcontainer-needed-no-excecutable ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (mocker-let ((get-buffer-create (name) ((:input '("*devcontainer stdout*") :occur 0)))
                 (devcontainer-find-executable () ((:output nil)))
                 (user-error (msg) ((:input '("Don't have devcontainer executable.")))))
      (devcontainer-up))))

(ert-deftest devcontainer-image-id-non-existent ()
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (should-not (devcontainer-image-id))))

(ert-deftest devcontainer-image-id-existent ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((project-name (file-name-nondirectory (directory-file-name (file-name-directory project-root-dir))))
          (root-dir-name (directory-file-name project-root-dir)))
      (mocker-let ((secure-hash (algorithm string) ((:input `(sha256 ,root-dir-name) :output "abcdef")))
                   (project-name (pr) ((:input `((foo . ,project-root-dir)) :output project-name))))
        (should (equal (devcontainer-image-id) (format "vcs-%s-abcdef" project-name)))))))

(ert-deftest container-up-devcontainer-needed-excecutable-available ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((stdout-buf (get-buffer-create "*devcontainer stdout*"))
          (cmd `("/some/path/devcontainer" "up" "--workspace-folder" ,project-root-dir)))
      (mocker-let ((get-buffer-create (name) ((:input '("*devcontainer stdout*") :output stdout-buf)))
                   (devcontainer-find-executable () ((:output "/some/path/devcontainer")))
                   (user-error (msg) ((:input '("Don't have devcontainer executable.") :occur 0)))
                   (make-process (&rest args)
                                 ((:input `(:name "devcontainer up"
                                            :command ,cmd
                                            :buffer ,stdout-buf
                                            :filter devcontainer--build-process-stdout-filter
                                            :sentinel devcontainer--build-sentinel)
                                   :output 'proc))))
       (devcontainer-up)))))

(ert-deftest container-up-sentinel-success ()
  (with-temp-buffer
    (insert "{\"outcome\":\"success\",\"containerId\":\"8af87509ac808da58ff21688019836b1d73ffea8b421b56b5c54b8f18525f382\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"/workspaces/devcontainer.el\"}")
    (mocker-let ((process-buffer (proc) ((:input '("devcontainer up") :output (current-buffer))))
                 (message (msg id) ((:input '("Sucessfully brought up container id %s" "8af87509ac80")))))
      (devcontainer--build-sentinel "devcontainer up" "finished")
      (should (string-suffix-p "Process devcontainer up finished" (buffer-string))))))


(ert-deftest container-up-sentinel-defined-failure ()
  (with-temp-buffer
    (insert "{\"outcome\":\"error\",\"message\":\"Some error message\",\"description\":\"some description\"}")
    (mocker-let ((process-buffer (proc) ((:input '("devcontainer up") :output (current-buffer))))
                 (user-error (tmpl outcome msg desc) ((:input '("%s: %s – %s" "error" "Some error message" "some description")))))
      (devcontainer--build-sentinel "devcontainer up" "exited abnormally with code 1")
      (should (string-suffix-p "Process devcontainer up exited abnormally with code 1" (buffer-string))))))

(ert-deftest container-up-sentinel-defined-garbled ()
  (with-temp-buffer
    (insert "Some non json stuff")
    (mocker-let ((process-buffer (proc) ((:input '("devcontainer up") :output (current-buffer))))
                 (user-error (msg) ((:input '("Garbeled output from `devcontainer up'. See *devcontainer stdout* buffer.")))))
      (devcontainer--build-sentinel "devcontainer up" "exited abnormally with code 1")
      (should (string-suffix-p "Process devcontainer up exited abnormally with code 1" (buffer-string))))))

(ert-deftest kill-container-existent ()
  (mocker-let ((devcontainer-container-up () ((:output "8af87509ac80")))
               (shell-command-to-string (cmd) ((:input '("docker container kill 8af87509ac80"))))
               (message (tmpl container-id) ((:input '("Killed container %s" "8af87509ac80")))))
    (devcontainer-kill-container)))

(ert-deftest kill-container-non-existent ()
  (mocker-let ((devcontainer-container-up () ((:output nil)))
               (user-error (msg) ((:input '("No container running")))))
    (devcontainer-kill-container)))

(ert-deftest remove-container-existent ()
  (mocker-let ((devcontainer-container-id () ((:output "8af87509ac80")))
               (shell-command-to-string (cmd) ((:input '("docker container kill 8af87509ac80"))
                                               (:input '("docker container rm 8af87509ac80"))))
               (message (tmpl container-id) ((:input '("Removed container %s" "8af87509ac80")))))
    (devcontainer-remove-container)))

(ert-deftest remove-container-non-existent ()
  (mocker-let ((devcontainer-container-id () ((:output nil)))
               (user-error (msg) ((:input '("No container to be removed")))))
    (devcontainer-remove-container)))

(ert-deftest remove-image-non-existent ()
  (mocker-let ((devcontainer-container-needed () ((:output nil)))
               (user-error (msg) ((:input '("No devcontainer for current project")))))
    (devcontainer-remove-image)))

(ert-deftest remove-image-existent ()
  (mocker-let ((devcontainer-container-id () ((:output "8af87509ac80")))
               (devcontainer-image-id () ((:output "vcs-foo-abcdef")))
               (shell-command-to-string (cmd) ((:input '("docker container kill 8af87509ac80"))
                                               (:input '("docker container rm 8af87509ac80"))
                                               (:input '("docker image rm vcs-foo-abcdef"))))
               (message (tmpl container-id) ((:input '("Removed image %s" "vcs-foo-abcdef")))))
    (devcontainer-remove-image)))

(ert-deftest restart-container-non-existent ()
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (mocker-let ((user-error (msg) ((:input '("No devcontainer for current project")))))
      (devcontainer-restart))))

(ert-deftest restart-container-not-up ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (mocker-let ((devcontainer-container-up () ((:output nil)))
                 (devcontainer-up () ((:output t))))
      (devcontainer-restart))))

(ert-deftest restart-container-up ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (mocker-let ((devcontainer-container-up () ((:output t)))
                 (devcontainer-kill-container () ((:output t)))
                 (devcontainer-up () ((:output t))))
      (devcontainer-restart))))

(ert-deftest rebuild-and-restart-container-non-existent ()
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (mocker-let ((user-error (msg) ((:input '("No devcontainer for current project")))))
      (devcontainer-rebuild-and-restart))))

(ert-deftest rebuild-and-restart-container-not-up ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (mocker-let ((devcontainer-container-up () ((:output nil)))
                 (devcontainer-remove-image () ((:output t)))
                 (devcontainer-up () ((:output t))))
      (devcontainer-rebuild-and-restart))))

(ert-deftest rebuild-and-restart-container-up ()
  (fixture-tmp-dir "test-repo-devcontainer"
    (mocker-let ((devcontainer-container-up () ((:output t)))
                 (devcontainer-remove-container () ((:output t)))
                 (devcontainer-remove-image () ((:output t)))
                 (devcontainer-up () ((:output t))))
      (devcontainer-rebuild-and-restart))))

(ert-deftest compile-start-advice-devcontainer-down ()
  (devcontainer-mode 1)
  (fixture-tmp-dir "test-repo-devcontainer"
    (mocker-let ((devcontainer-container-up () ((:output nil)))
                 (message (msg) ((:input '("Devcontainer not running. Please start it first.")))))
      (devcontainer--compile-start-advice #'my-compile-fun "my-command foo"))))

(ert-deftest compilation-start-advised ()
  (devcontainer-mode 1)
  (should (advice-member-p 'devcontainer--compile-start-advice 'compilation-start))
  (devcontainer-mode -1)
  (should-not (advice-member-p 'devcontainer--compile-start-advice 'compilation-start)))

(ert-deftest compile-start-advice-no-devcontainer-mode ()
  (devcontainer-mode -1)
  (mocker-let ((my-compile-fun (command &rest rest) ((:input '("my-command foo" mode name-function hight-light-regexp continue)))))
    (devcontainer--compile-start-advice #'my-compile-fun "my-command foo" 'mode 'name-function 'hight-light-regexp 'continue)))

(ert-deftest compile-start-advice-devcontainer-mode-no-devcontainer ()
  (devcontainer-mode 1)
  (fixture-tmp-dir "test-repo-no-devcontainer"
    (mocker-let ((my-compile-fun (command &rest rest) ((:input '("my-command foo")))))
      (devcontainer--compile-start-advice #'my-compile-fun "my-command foo"))))

(ert-deftest compile-start-advice-devcontainer-up ()
  (devcontainer-mode 1)
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd "devcontainer exec --workspace-folder . my-command foo"))
      (mocker-let ((my-compile-fun (command &rest rest) ((:input `(,cmd))))
                   (devcontainer-container-up () ((:output "8af87509ac80"))))
       (devcontainer--compile-start-advice #'my-compile-fun "my-command foo")))))

(ert-deftest compilation-start-no-exclude-simple ()
  (devcontainer-mode 1)
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd "devcontainer exec --workspace-folder . grep foo")
          (devcontainer-execute-outside-container nil))
    (mocker-let ((my-compile-fun (command &rest rest) ((:input `(,cmd))))
                 (devcontainer-container-up () ((:output "abcdef"))))
      (devcontainer--compile-start-advice #'my-compile-fun "grep foo")))))

(ert-deftest compilation-start-exclude-simple ()
  (devcontainer-mode 1)
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd "grep foo")
          (devcontainer-execute-outside-container '("grep" "rg")))
    (mocker-let ((my-compile-fun (command &rest rest) ((:input `(,cmd)))))
      (devcontainer--compile-start-advice #'my-compile-fun "grep foo")))))

(ert-deftest compilation-start-exclude-absolute-path ()
  (devcontainer-mode 1)
  (fixture-tmp-dir "test-repo-devcontainer"
    (let ((cmd "/usr/bin/rg foo")
          (devcontainer-execute-outside-container '("grep" "rg")))
    (mocker-let ((my-compile-fun (command &rest rest) ((:input `(,cmd)))))
      (devcontainer--compile-start-advice #'my-compile-fun "/usr/bin/rg foo")))))
