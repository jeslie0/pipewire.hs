module Main (main) where

import Pipewire qualified as PW

main :: IO ()
main = PW.withInstance () printEvent \pwInstance -> do
    PW.pw_main_loop_run pwInstance.mainLoop
  where
    printEvent _pwInstance ev () = do
        case ev of
            PW.ChangedNode pwid props -> do
                putStrLn $ "changed: " <> show pwid
                printProps props
            PW.Added pwid name props -> do
                putStrLn $ "added: " <> show pwid
                putStrLn $ " type: " <> show name
                printProps props
            PW.Removed pwid -> do
                putStrLn $ "removed: " <> show pwid
        putStrLn ""
    printProps props = mapM_ (putStrLn . mappend " " . show) =<< PW.spaDictRead props
